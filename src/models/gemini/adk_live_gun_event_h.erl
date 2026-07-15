%% @doc Minimal Gun event handler used to acknowledge outbound WebSocket
%% frames only after Gun has handed the complete frame to its socket
%% transport.  All other events are deliberately metadata-free no-ops.
-module(adk_live_gun_event_h).
-behaviour(gun_event).

-export([init/2, domain_lookup_start/2, domain_lookup_end/2,
         connect_start/2, connect_end/2,
         tls_handshake_start/2, tls_handshake_end/2,
         request_start/2, request_headers/2, request_end/2,
         push_promise_start/2, push_promise_end/2,
         response_start/2, response_inform/2, response_headers/2,
         response_trailers/2, response_end/2, ws_upgrade/2,
         ws_recv_frame_start/2, ws_recv_frame_header/2,
         ws_recv_frame_end/2, ws_send_frame_start/2,
         ws_send_frame_end/2, protocol_changed/2, origin_changed/2,
         cancel/2, disconnect/2, terminate/2]).

init(_Event, State) -> State.
domain_lookup_start(_Event, State) -> State.
domain_lookup_end(_Event, State) -> State.
connect_start(_Event, State) -> State.
connect_end(_Event, State) -> State.
tls_handshake_start(_Event, State) -> State.
tls_handshake_end(_Event, State) -> State.
request_start(_Event, State) -> State.
request_headers(_Event, State) -> State.
request_end(_Event, State) -> State.
push_promise_start(_Event, State) -> State.
push_promise_end(_Event, State) -> State.
response_start(_Event, State) -> State.
response_inform(_Event, State) -> State.
response_headers(_Event, State) -> State.
response_trailers(_Event, State) -> State.
response_end(_Event, State) -> State.
ws_upgrade(_Event, State) -> State.
ws_recv_frame_start(_Event, State) -> State.
ws_recv_frame_header(_Event, State) -> State.
ws_recv_frame_end(_Event, State) -> State.
ws_send_frame_start(_Event, State) -> State.

ws_send_frame_end(#{stream_ref := StreamRef},
                  #{owner := Owner} = State) when is_pid(Owner) ->
    Owner ! {adk_live_gun_event, self(),
             {ws_send_frame_end, StreamRef}},
    State;
ws_send_frame_end(_Event, State) -> State.

protocol_changed(_Event, State) -> State.
origin_changed(_Event, State) -> State.
cancel(_Event, State) -> State.
disconnect(_Event, State) -> State.
terminate(_Event, State) -> State.
