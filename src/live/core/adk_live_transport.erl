%% @doc Injected full-duplex transport contract for Live providers.
%%
%% `open/2' returns a private handle and asynchronously reports transport
%% state to Owner using the messages below.  `send/2' may return `busy'; the
%% session then retains the frame in its bounded ingress queue until a
%% `writable' message arrives.
%%
%%   {adk_live_transport, Handle, connected}
%%   {adk_live_transport, Handle, writable}
%%   {adk_live_transport, Handle, {sent, SendRef}}
%%   {adk_live_transport, Handle, {frame, Binary}}
%%   {adk_live_transport, Handle, {closed, OpaqueReason}}
%%
%% Implementations must redact credentials, endpoint query strings and
%% provider resumption handles from errors and diagnostic state.
-module(adk_live_transport).

-type handle() :: pid() | port() | reference() | term().

-export_type([handle/0]).

-callback open(Owner :: pid(), Options :: map()) ->
    {ok, handle()} | {error, term()}.
-callback send(Handle :: handle(), Frame :: binary()) ->
    %% `ok' means synchronously consumed. `{ok, SendRef}' retains session
    %% ingress credit until the matching `sent' notification arrives.
    ok | {ok, term()} | {error, busy | term()}.
-callback close(Handle :: handle(), Reason :: term()) -> ok.

%% Optional inbound-flow acknowledgement. A flow-controlled transport should
%% replenish provider/socket credit only after the session has decoded and
%% admitted the frame.
-callback consumed(Handle :: handle(), Count :: pos_integer()) -> ok.
-optional_callbacks([consumed/2]).
