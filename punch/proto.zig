//
// these magic values were randomly generated
//
// Client/Server
//
// The client connects to the server for punch communication. Once connected, each side will send 8-bytes to identify which role they are taking (i.e. the 'initiator' or the 'forwarder').
//
// Initiator/Forwarder Roles:
//
// The 'initiator' is the one who can send the 'OpenTunnel' message to establish a new tunneled-connection through the punch data stream.
// The 'initator' will have a "raw server" socket waiting for connections.
// The 'forwader' will make a new "raw client" connection when it receives the OpenTunnel message.
//
pub const magic = [8]u8 { 0x8e, 0xc0, 0x4f, 0xf4, 0xa0, 0x0e, 0x86, 0x94 };

pub const Role = enum(u8) {
    initiator = 0,
    forwarder = 1,
};
// TODO: it's possible an endpoint could be both an initator and a forwarder
//       if I find a use-case for this, I can make an initiator and forwarder flag
pub const initiatorHandshake = magic ++ [1]u8 {@enumToInt(Role.initiator)};
pub const forwarderHandshake = magic ++ [1]u8 {@enumToInt(Role.forwarder)};

pub const TwoWayMessage = struct {
    pub const Heartbeat = 0;
    pub const CloseTunnel = 1;
    pub const Data = 2;
};
pub const InitiatorMessage = struct {
    pub const OpenTunnel = 128;
};
pub const ForwarderMessage = struct {
};
