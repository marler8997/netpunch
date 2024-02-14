# Punch Protocol

Connection is initiated with a handshake. 8 bytes for the punch protocol magic value `0x8ec04ff4a00e8694`, then 1-byte indicating which role the endpoint is taking.  `0` for the initiator role which will be opening tunnels, and `1` for the forwarder role which will accept OpenTunnel messages and forward the tunnel data to another endpoint.

> TODO: support authentication? Allow an authenticate command which requires a sequence of bytes to be sent from the other endpoint.

### Common Messages

| Message     | ID| Length           | Data    |
|-------------|---|------------------|---------|
| Heartbeat   | 0 |                  |         |
| CloseTunnel | 1 |                  |         |
| Data        | 2 | Length (8 bytes) | Data... |

### InitiatorOnly Messages

| Message     | ID| Length           | Data    |
|-------------|---|------------------|---------|
| OpenTunnel  |128|                  |         |
