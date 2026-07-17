%% @doc Behaviour contract for supervised ambient trigger adapters.
%%
%% A trigger source owns only transport/scheduling concerns. It must turn each
%% delivery into the bounded `adk_ambient:submit/2' call and must never execute
%% an agent itself. Calling submit/2 (rather than casting into the runtime)
%% applies backpressure before a source accepts another delivery.
%%
%% Pub/Sub, Eventarc, RabbitMQ, Kafka, and similar integrations can implement
%% this behaviour without adding those SDKs to erlang_adk. The bundled
%% `adk_trigger_schedule' module is the reference implementation.
-module(adk_trigger_source).

-export_type([event/0, source_status/0]).

-type event() :: #{payload := term(),
                   idempotency_key := binary(),
                   session => #{user_id := binary(),
                                session_id := binary()},
                   timeout_ms => non_neg_integer() | infinity}.
-type source_status() :: map().

-callback child_spec(map()) -> supervisor:child_spec().
-callback start_link(map()) -> gen_server:start_ret().
-callback status(pid()) -> {ok, source_status()} | {error, term()}.
-callback stop(pid()) -> ok | {error, term()}.

