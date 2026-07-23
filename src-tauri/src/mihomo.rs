use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Duration;
use tokio::process::Command;

const HELPER_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Clone)]
pub struct MihomoClient {
    helper: PathBuf,
    helper_timeout: Duration,
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

#[derive(Debug)]
pub struct ControlError;

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
struct SnapshotEnvelope {
    configs: ConfigResponse,
    proxies: ProxiesResponse,
}

#[derive(Deserialize)]
struct TrayStateEnvelope {
    snapshot: Option<SnapshotEnvelope>,
    #[serde(default)]
    profiles: TrayProfiles,
    health: Option<TrayHealth>,
}

#[derive(Default, Deserialize)]
struct TrayProfiles {
    #[serde(default)]
    profiles: Vec<String>,
    active_profile: Option<String>,
}

#[derive(Deserialize)]
struct TrayHealth {
    network_consistent: bool,
}

#[derive(Default)]
pub struct TrayPoll {
    pub snapshot: Snapshot,
    pub profiles: Vec<String>,
    pub active_profile: Option<String>,
    pub network_consistent: Option<bool>,
}

#[derive(Deserialize)]
struct ConfigResponse {
    #[serde(default)]
    mode: String,
    #[serde(default)]
    tun: TunConfig,
}

#[derive(Default, Deserialize)]
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

#[derive(Deserialize)]
struct DelayResult {
    succeeded: usize,
}

impl MihomoClient {
    pub fn new(helper: PathBuf) -> Self {
        Self {
            helper,
            helper_timeout: HELPER_TIMEOUT,
        }
    }

    async fn invoke(&self, arguments: &[&str]) -> Result<Vec<u8>, ControlError> {
        let mut command = Command::new(&self.helper);
        command.arg("rpc").args(arguments).kill_on_drop(true);
        let output = tokio::time::timeout(self.helper_timeout, command.output())
            .await
            .map_err(|_| ControlError)?
            .map_err(|_| ControlError)?;
        if !output.status.success() {
            return Err(ControlError);
        }
        Ok(output.stdout)
    }

    pub async fn tray_state(&self) -> Result<TrayPoll, ControlError> {
        let bytes = self.invoke(&["tray-state"]).await?;
        let envelope =
            serde_json::from_slice::<TrayStateEnvelope>(&bytes).map_err(|_| ControlError)?;
        Ok(TrayPoll {
            snapshot: envelope
                .snapshot
                .map(snapshot_from_envelope)
                .unwrap_or_default(),
            profiles: envelope.profiles.profiles,
            active_profile: envelope.profiles.active_profile,
            network_consistent: envelope.health.map(|health| health.network_consistent),
        })
    }

    pub async fn controller_available(&self) -> bool {
        self.invoke(&["version"]).await.is_ok()
    }

    async fn fetch_snapshot(&self) -> Result<Snapshot, ControlError> {
        let bytes = self.invoke(&["snapshot"]).await?;
        parse_snapshot(&bytes).ok_or(ControlError)
    }

    pub async fn set_tun(&self, enabled: bool) -> Result<(), ControlError> {
        self.invoke(&["set-tun", if enabled { "true" } else { "false" }])
            .await?;
        Ok(())
    }

    pub async fn set_mode(&self, mode: &str) -> Result<(), ControlError> {
        self.invoke(&["set-mode", mode]).await?;
        Ok(())
    }

    pub async fn apply_outbound_mode(&self, mode: &str) -> Result<Snapshot, ModeApplyError> {
        if mode.eq_ignore_ascii_case("global") {
            let before = self
                .fetch_snapshot()
                .await
                .map_err(|_| ModeApplyError::Request)?;
            let target = before
                .global_proxy_target()
                .ok_or(ModeApplyError::NoGlobalProxy)?;
            let current = before.group("GLOBAL").map(|group| group.current.as_str());
            if current != Some(target.as_str()) {
                self.select_proxy("GLOBAL", &target)
                    .await
                    .map_err(|_| ModeApplyError::Request)?;
            }
        }

        self.set_mode(mode)
            .await
            .map_err(|_| ModeApplyError::Request)?;
        let observed = self
            .fetch_snapshot()
            .await
            .map_err(|_| ModeApplyError::Request)?;
        if observed.outbound_mode_applied(mode) {
            Ok(observed)
        } else {
            Err(ModeApplyError::ReadbackMismatch)
        }
    }

    pub async fn select_proxy(&self, group: &str, proxy: &str) -> Result<(), ControlError> {
        self.invoke(&["select-proxy", group, proxy]).await?;
        Ok(())
    }

    pub async fn test_delays(&self, proxies: &[String]) -> usize {
        if proxies.is_empty() {
            return 0;
        }
        let mut arguments = vec!["test-delay"];
        arguments.extend(proxies.iter().map(String::as_str));
        let Ok(bytes) = self.invoke(&arguments).await else {
            return 0;
        };
        serde_json::from_slice::<DelayResult>(&bytes)
            .map(|result| result.succeeded)
            .unwrap_or(0)
    }
}

fn parse_snapshot(bytes: &[u8]) -> Option<Snapshot> {
    let response = serde_json::from_slice::<SnapshotEnvelope>(bytes).ok()?;
    Some(snapshot_from_envelope(response))
}

fn snapshot_from_envelope(response: SnapshotEnvelope) -> Snapshot {
    let proxies = response.proxies.proxies;
    let mut groups = proxies
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
                        .get(node)
                        .and_then(|entry| entry.history.last())
                        .map(|entry| entry.delay),
                })
                .collect(),
        })
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| {
        let left_selector = proxies
            .get(&left.name)
            .is_some_and(|value| value.kind.eq_ignore_ascii_case("selector"));
        let right_selector = proxies
            .get(&right.name)
            .is_some_and(|value| value.kind.eq_ignore_ascii_case("selector"));
        right_selector
            .cmp(&left_selector)
            .then_with(|| left.name.cmp(&right.name))
    });
    Snapshot {
        reachable: true,
        enhanced_tun: response.configs.tun.enable,
        mode: response.configs.mode.to_lowercase(),
        groups,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    fn node(name: &str) -> ProxyNode {
        ProxyNode {
            name: name.to_string(),
            delay: None,
        }
    }

    #[test]
    fn snapshot_maps_tun_mode_selectors_and_delay() {
        let snapshot = parse_snapshot(
            br#"{
            "configs":{"mode":"Rule","tun":{"enable":true}},
            "proxies":{"proxies":{
                "PROXY":{"type":"Selector","now":"Node B","all":["Node A","Node B"]},
                "Node A":{"type":"Shadowsocks","history":[{"delay":41}]},
                "Node B":{"type":"Shadowsocks","history":[{"delay":88}]}
            }}
        }"#,
        )
        .expect("snapshot");
        assert!(snapshot.reachable);
        assert!(snapshot.enhanced_tun);
        assert_eq!(snapshot.mode, "rule");
        assert_eq!(snapshot.groups[0].current, "Node B");
        assert_eq!(snapshot.groups[0].proxies[0].delay, Some(41));
        assert_eq!(snapshot.groups[0].proxies[1].delay, Some(88));
    }

    #[test]
    fn global_mode_requires_a_proxy_route_not_only_a_mode_string() {
        let snapshot = Snapshot {
            reachable: true,
            mode: "global".to_string(),
            groups: vec![ProxyGroup {
                name: "GLOBAL".to_string(),
                current: "DIRECT".to_string(),
                proxies: vec![node("DIRECT"), node("Proxy")],
            }],
            ..Snapshot::default()
        };
        assert!(!snapshot.outbound_mode_applied("global"));
        assert_eq!(snapshot.global_proxy_target().as_deref(), Some("Proxy"));
    }

    #[test]
    fn default_snapshot_is_unreachable_and_safe() {
        let snapshot = Snapshot::default();
        assert!(!snapshot.reachable);
        assert!(!snapshot.enhanced_tun);
        assert!(snapshot.groups.is_empty());
    }

    #[test]
    fn controller_availability_probes_version_through_the_helper() {
        let root =
            std::env::temp_dir().join(format!("mihomobox-controller-probe-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create fixture");
        let helper = root.join("mihomoboxctl");
        fs::write(
            &helper,
            "#!/bin/sh\n[ \"$1\" = rpc ] && [ \"$2\" = version ] && printf '{\"version\":\"test\"}\\n'\n",
        )
        .expect("write helper");
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).expect("secure helper");
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        assert!(runtime.block_on(MihomoClient::new(helper).controller_available()));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn helper_invocation_is_bounded_by_timeout() {
        let root =
            std::env::temp_dir().join(format!("mihomobox-helper-timeout-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create fixture");
        let helper = root.join("mihomoboxctl");
        fs::write(&helper, "#!/bin/sh\nsleep 2\n").expect("write helper");
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).expect("secure helper");
        let client = MihomoClient {
            helper,
            helper_timeout: Duration::from_millis(25),
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        assert!(runtime.block_on(client.invoke(&["tray-state"])).is_err());
        fs::remove_dir_all(root).expect("remove fixture");
    }
}
