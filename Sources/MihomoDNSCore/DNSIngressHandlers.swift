import Foundation
@preconcurrency import NIOCore
import NIOFoundationCompat
@preconcurrency import NIOPosix

final class DNSUDPHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let forwarder: DNSForwarding
    private let threadPool: NIOThreadPool

    init(forwarder: DNSForwarding, threadPool: NIOThreadPool) {
        self.forwarder = forwarder
        self.threadPool = threadPool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        guard let query = envelope.data.readData(length: envelope.data.readableBytes) else { return }
        let remoteAddress = envelope.remoteAddress
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        threadPool.runIfActive(eventLoop: context.eventLoop) { [forwarder] in
            try forwarder.forward(query)
        }.whenSuccess { response in
            let context = loopBoundContext.value
            var buffer = context.channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            context.writeAndFlush(self.wrapOutboundOut(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ServiceLog.error("event=udp_listener_error")
    }
}

struct DNSTCPFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 2,
              let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self) else {
            return .needMoreData
        }
        let count = Int(length)
        guard count >= 12, count <= DNSMessage.maximumWireLength else {
            throw DNSMessageError.invalidLength
        }
        guard buffer.readableBytes >= count + 2 else {
            return .needMoreData
        }
        buffer.moveReaderIndex(forwardBy: 2)
        guard let frame = buffer.readSlice(length: count) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }
}

final class DNSTCPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let forwarder: DNSForwarding
    private let threadPool: NIOThreadPool

    init(forwarder: DNSForwarding, threadPool: NIOThreadPool) {
        self.forwarder = forwarder
        self.threadPool = threadPool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        guard let query = input.readData(length: input.readableBytes) else { return }
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        threadPool.runIfActive(eventLoop: context.eventLoop) { [forwarder] in
            try forwarder.forward(query)
        }.whenComplete { result in
            let context = loopBoundContext.value
            switch result {
            case .success(let response):
                var output = context.channel.allocator.buffer(capacity: response.count + 2)
                output.writeInteger(UInt16(response.count))
                output.writeBytes(response)
                context.writeAndFlush(self.wrapOutboundOut(output), promise: nil)
            case .failure:
                context.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ServiceLog.error("event=tcp_listener_error")
        context.close(promise: nil)
    }
}
