use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

#[derive(Clone)]
pub struct MihomoClient {
    base_url: String,
    client: reqwest::Client,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub reachable: bool,
    pub enhanced_tun: bool,
    pub mode: String,
    pub groups: Vec<ProxyGroup>,
}

#[derive(Clone, Debug)]
pub struct ProxyGroup {
    pub name: String,
    pub current: String,
    pub proxies: Vec<ProxyNode>,
}

#[derive(Clone, Debug)]
pub struct ProxyNode {
    pub name: String,
    pub delay: Option<u64>,
}

#[derive(Debug)]
pub enum ModeApplyError {
    Request,
    NoGlobalProxy,
    ReadbackMismatch,
}

impl From<reqwest::Error> for ModeApplyError {
    fn from(_: reqwest::Error) -> Self {
        Self::Request
    }
}

impl Snapshot {
    fn group(&self, name: &str) -> Option<&ProxyGroup> {
        self.groups
            .iter()
            .find(|group| group.name.eq_ignore_ascii_case(name))
    }

    fn target_routes_through_proxy(&self, target: &str, visited: &mut HashSet<String>) -> bool {
        if is_direct_builtin(target) {
            return false;
        }
        let Some(group) = self.group(target) else {
            return true;
        };
        let key = group.name.to_lowercase();
        if !visited.insert(key.clone()) || group.current.is_empty() {
            return false;
        }
        let routes_through_proxy = self.target_routes_through_proxy(&group.current, visited);
        visited.remove(&key);
        routes_through_proxy
    }

    fn global_proxy_target(&self) -> Option<String> {
        let global = self.group("GLOBAL")?;
        if !global.current.is_empty()
            && self.target_routes_through_proxy(&global.current, &mut HashSet::new())
        {
            return Some(global.current.clone());
        }
        global
            .proxies
            .iter()
            .find(|proxy| {
                self.group(&proxy.name)
                    .is_some_and(|group| !group.name.eq_ignore_ascii_case("GLOBAL"))
                    && self.target_routes_through_proxy(&proxy.name, &mut HashSet::new())
            })
            .or_else(|| {
                global.proxies.iter().find(|proxy| {
                    self.target_routes_through_proxy(&proxy.name, &mut HashSet::new())
                })
            })
            .map(|proxy| proxy.name.clone())
    }

    fn global_routes_through_proxy(&self) -> bool {
        self.group("GLOBAL").is_some_and(|global| {
            !global.current.is_empty()
                && self.target_routes_through_proxy(&global.current, &mut HashSet::new())
        })
    }

    pub fn outbound_mode_applied(&self, requested: &str) -> bool {
        if !self.reachable || !self.mode.eq_ignore_ascii_case(requested) {
            return false;
        }
        !requested.eq_ignore_ascii_case("global") || self.global_routes_through_proxy()
    }
}

fn is_direct_builtin(name: &str) -> bool {
    matches!(
        name.to_ascii_uppercase().as_str(),
        "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS"
    )
}

#[derive(Deserialize)]
struct ConfigResponse {
    #[serde(default)]
    mode: String,
    #[serde(default)]
    tun: TunConfig,
}

#[derive(Default, Deserialize, Serialize)]
struct TunConfig {
    #[serde(default)]
    enable: bool,
}

#[derive(Deserialize)]
struct ProxiesResponse {
    proxies: HashMap<String, ProxyResponse>,
}

#[derive(Deserialize)]
struct ProxyResponse {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    now: String,
    #[serde(default)]
    all: Vec<String>,
    #[serde(default)]
    history: Vec<DelayEntry>,
}

#[derive(Deserialize)]
struct DelayEntry {
    delay: u64,
}

impl MihomoClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(4))
                .build()
                .expect("reqwest client"),
        }
    }

    pub async fn snapshot(&self) -> Snapshot {
        self.fetch_snapshot().await.unwrap_or_default()
    }

    async fn fetch_snapshot(&self) -> reqwest::Result<Snapshot> {
        let configs = self
            .client
            .get(format!("{}/configs", self.base_url))
            .send()
            .await?
            .error_for_status()?
            .json::<ConfigResponse>()
            .await?;
        let proxies = self
            .client
            .get(format!("{}/proxies", self.base_url))
            .send()
            .await?
            .error_for_status()?
            .json::<ProxiesResponse>()
            .await?;

        let mut groups = proxies
            .proxies
            .iter()
            .filter(|(_, value)| !value.all.is_empty())
            .map(|(name, value)| ProxyGroup {
                name: name.clone(),
                current: value.now.clone(),
                proxies: value
                    .all
                    .iter()
                    .map(|node| ProxyNode {
                        name: node.clone(),
                        delay: proxies
                            .proxies
                            .get(node)
                            .and_then(|entry| entry.history.last())
                            .map(|entry| entry.delay),
                    })
                    .collect(),
            })
            .collect::<Vec<_>>();
        groups.sort_by(|left, right| {
            let left_selector = proxies
                .proxies
                .get(&left.name)
                .is_some_and(|value| value.kind.eq_ignore_ascii_case("selector"));
            let right_selector = proxies
                .proxies
                .get(&right.name)
                .is_some_and(|value| value.kind.eq_ignore_ascii_case("selector"));
            right_selector
                .cmp(&left_selector)
                .then_with(|| left.name.cmp(&right.name))
        });

        Ok(Snapshot {
            reachable: true,
            enhanced_tun: configs.tun.enable,
            mode: configs.mode.to_lowercase(),
            groups,
        })
    }

    pub async fn set_tun(&self, enabled: bool) -> reqwest::Result<()> {
        self.client
            .patch(format!("{}/configs", self.base_url))
            .json(&serde_json::json!({ "tun": { "enable": enabled } }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    pub async fn set_mode(&self, mode: &str) -> reqwest::Result<()> {
        self.client
            .patch(format!("{}/configs", self.base_url))
            .json(&serde_json::json!({ "mode": mode }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    pub async fn apply_outbound_mode(&self, mode: &str) -> Result<Snapshot, ModeApplyError> {
        if mode.eq_ignore_ascii_case("global") {
            let before = self.fetch_snapshot().await?;
            let target = before
                .global_proxy_target()
                .ok_or(ModeApplyError::NoGlobalProxy)?;
            let current = before.group("GLOBAL").map(|group| group.current.as_str());
            if current != Some(target.as_str()) {
                self.select_proxy("GLOBAL", &target).await?;
            }
        }

        self.set_mode(mode).await?;
        let observed = self.fetch_snapshot().await?;
        if observed.outbound_mode_applied(mode) {
            Ok(observed)
        } else {
            Err(ModeApplyError::ReadbackMismatch)
        }
    }

    pub async fn select_proxy(&self, group: &str, proxy: &str) -> reqwest::Result<()> {
        self.client
            .put(format!(
                "{}/proxies/{}",
                self.base_url,
                urlencoding::encode(group)
            ))
            .json(&serde_json::json!({ "name": proxy }))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::mpsc;
    use std::thread;

    #[test]
    fn default_snapshot_is_unreachable_and_safe() {
        let snapshot = Snapshot::default();
        assert!(!snapshot.reachable);
        assert!(!snapshot.enhanced_tun);
        assert!(snapshot.groups.is_empty());
    }

    #[test]
    fn snapshot_maps_tun_mode_selectors_and_delay() {
        let (base_url, server) = serve(vec![
            r#"{"mode":"Rule","tun":{"enable":true}}"#,
            r#"{"proxies":{"PROXY":{"type":"Selector","now":"Node B","all":["Node A","Node B"]},"Node A":{"type":"Shadowsocks","history":[{"delay":41}]},"Node B":{"type":"Shadowsocks","history":[{"delay":88}]}}}"#,
        ]);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let snapshot = runtime.block_on(MihomoClient::new(base_url).snapshot());
        server.join().expect("server");

        assert!(snapshot.reachable);
        assert!(snapshot.enhanced_tun);
        assert_eq!(snapshot.mode, "rule");
        assert_eq!(snapshot.groups.len(), 1);
        assert_eq!(snapshot.groups[0].name, "PROXY");
        assert_eq!(snapshot.groups[0].current, "Node B");
        assert_eq!(snapshot.groups[0].proxies[0].delay, Some(41));
        assert_eq!(snapshot.groups[0].proxies[1].delay, Some(88));
    }

    #[test]
    fn mutations_use_mihomo_controller_contract() {
        let (base_url, server, requests) = capture(3);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let client = MihomoClient::new(base_url);
            client.set_tun(true).await.expect("set tun");
            client.set_mode("global").await.expect("set mode");
            client
                .select_proxy("Primary Group", "Node B")
                .await
                .expect("select proxy");
        });
        server.join().expect("server");
        let requests = requests.recv().expect("requests");

        assert!(requests[0].starts_with("PATCH /configs HTTP/1.1\r\n"));
        assert!(requests[0].contains(r#"{"tun":{"enable":true}}"#));
        assert!(requests[1].contains(r#"{"mode":"global"}"#));
        assert!(requests[2].starts_with("PUT /proxies/Primary%20Group HTTP/1.1\r\n"));
        assert!(requests[2].contains(r#"{"name":"Node B"}"#));
    }

    #[test]
    fn global_mode_requires_a_proxy_route_not_only_a_mode_string() {
        let direct = Snapshot {
            reachable: true,
            mode: "global".to_string(),
            groups: vec![ProxyGroup {
                name: "GLOBAL".to_string(),
                current: "DIRECT".to_string(),
                proxies: vec![node("DIRECT"), node("Proxy")],
            }],
            ..Snapshot::default()
        };
        assert!(!direct.outbound_mode_applied("global"));
        assert_eq!(direct.global_proxy_target().as_deref(), Some("Proxy"));

        let nested = Snapshot {
            groups: vec![
                ProxyGroup {
                    name: "GLOBAL".to_string(),
                    current: "Proxy".to_string(),
                    proxies: vec![node("DIRECT"), node("Proxy")],
                },
                ProxyGroup {
                    name: "Proxy".to_string(),
                    current: "Node A".to_string(),
                    proxies: vec![node("Node A")],
                },
            ],
            ..direct
        };
        assert!(nested.outbound_mode_applied("global"));
        assert_eq!(nested.global_proxy_target().as_deref(), Some("Proxy"));
    }

    #[test]
    fn global_prefers_the_user_proxy_group_over_a_raw_node() {
        let snapshot = Snapshot {
            groups: vec![
                ProxyGroup {
                    name: "GLOBAL".to_string(),
                    current: "DIRECT".to_string(),
                    proxies: vec![node("DIRECT"), node("Raw Node"), node("Proxy")],
                },
                ProxyGroup {
                    name: "Proxy".to_string(),
                    current: "Selected Node".to_string(),
                    proxies: vec![node("Selected Node")],
                },
            ],
            ..Snapshot::default()
        };
        assert_eq!(snapshot.global_proxy_target().as_deref(), Some("Proxy"));
    }

    #[test]
    fn global_mode_rejects_nested_direct_and_selector_cycles() {
        let snapshot = Snapshot {
            reachable: true,
            mode: "global".to_string(),
            groups: vec![
                ProxyGroup {
                    name: "GLOBAL".to_string(),
                    current: "Fallback".to_string(),
                    proxies: vec![node("Fallback"), node("Cycle A")],
                },
                ProxyGroup {
                    name: "Fallback".to_string(),
                    current: "DIRECT".to_string(),
                    proxies: vec![node("DIRECT")],
                },
                ProxyGroup {
                    name: "Cycle A".to_string(),
                    current: "Cycle B".to_string(),
                    proxies: vec![node("Cycle B")],
                },
                ProxyGroup {
                    name: "Cycle B".to_string(),
                    current: "Cycle A".to_string(),
                    proxies: vec![node("Cycle A")],
                },
            ],
            ..Snapshot::default()
        };
        assert_eq!(snapshot.global_proxy_target(), None);
        assert!(!snapshot.outbound_mode_applied("global"));
    }

    #[test]
    fn applying_global_selects_a_proxy_before_changing_mode() {
        let before_proxies = r#"{"proxies":{"GLOBAL":{"type":"Selector","now":"DIRECT","all":["DIRECT","Proxy"]},"Proxy":{"type":"URLTest","now":"Node A","all":["Node A"]},"Node A":{"type":"Shadowsocks"},"DIRECT":{"type":"Direct"}}}"#;
        let after_proxies = r#"{"proxies":{"GLOBAL":{"type":"Selector","now":"Proxy","all":["DIRECT","Proxy"]},"Proxy":{"type":"URLTest","now":"Node A","all":["Node A"]},"Node A":{"type":"Shadowsocks"},"DIRECT":{"type":"Direct"}}}"#;
        let (base_url, server, requests) = serve_and_capture(vec![
            r#"{"mode":"rule","tun":{"enable":true}}"#,
            before_proxies,
            "{}",
            "{}",
            r#"{"mode":"global","tun":{"enable":true}}"#,
            after_proxies,
        ]);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let observed = runtime
            .block_on(MihomoClient::new(base_url).apply_outbound_mode("global"))
            .expect("apply global");
        server.join().expect("server");
        let requests = requests.recv().expect("requests");

        assert!(observed.outbound_mode_applied("global"));
        assert!(requests[2].starts_with("PUT /proxies/GLOBAL HTTP/1.1\r\n"));
        assert!(requests[2].contains(r#"{"name":"Proxy"}"#));
        assert!(requests[3].starts_with("PATCH /configs HTTP/1.1\r\n"));
        assert!(requests[3].contains(r#"{"mode":"global"}"#));
    }

    fn node(name: &str) -> ProxyNode {
        ProxyNode {
            name: name.to_string(),
            delay: None,
        }
    }

    fn serve(responses: Vec<&'static str>) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("address");
        let server = thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept");
                let _ = read_request(&mut stream);
                write_response(&mut stream, response);
            }
        });
        (format!("http://{address}"), server)
    }

    fn capture(count: usize) -> (String, thread::JoinHandle<()>, mpsc::Receiver<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("address");
        let (sender, receiver) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..count {
                let (mut stream, _) = listener.accept().expect("accept");
                requests.push(read_request(&mut stream));
                write_response(&mut stream, "{}");
            }
            sender.send(requests).expect("send requests");
        });
        (format!("http://{address}"), server, receiver)
    }

    fn serve_and_capture(
        responses: Vec<&'static str>,
    ) -> (String, thread::JoinHandle<()>, mpsc::Receiver<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("address");
        let (sender, receiver) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut requests = Vec::new();
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept");
                requests.push(read_request(&mut stream));
                write_response(&mut stream, response);
            }
            sender.send(requests).expect("send requests");
        });
        (format!("http://{address}"), server, receiver)
    }

    fn read_request(stream: &mut TcpStream) -> String {
        let mut bytes = Vec::new();
        let mut buffer = [0_u8; 1024];
        let mut expected_length = None;
        loop {
            let count = stream.read(&mut buffer).expect("read request");
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..count]);
            if let Some(header_end) = find_header_end(&bytes) {
                let headers = String::from_utf8_lossy(&bytes[..header_end]);
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|value| value.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                expected_length = Some(header_end + 4 + content_length);
            }
            if expected_length.is_some_and(|length| bytes.len() >= length) {
                break;
            }
        }
        String::from_utf8(bytes).expect("utf-8 request")
    }

    fn find_header_end(bytes: &[u8]) -> Option<usize> {
        bytes.windows(4).position(|window| window == b"\r\n\r\n")
    }

    fn write_response(stream: &mut TcpStream, body: &str) {
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .expect("write response");
    }
}
