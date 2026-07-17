%% @doc Behaviour for an isolated, serializable stateful plugin instance.
%%
%% Stateful callbacks run in bounded workers against an immutable state
%% snapshot. adk_plugin_instance commits the returned state only when that
%% worker completed before the invocation deadline and the caller is still
%% alive. This keeps late or abandoned callbacks from mutating policy state.
%% Instances use PID identity and are supervised as temporary children. They
%% are not restarted after failure because doing so would reset state behind a
%% new PID; owners explicitly create and distribute a replacement instead.
-module(adk_stateful_plugin).

-type callback_result() :: adk_plugin:result().
-type state() :: term().
-export_type([callback_result/0, state/0]).

-callback init(Config :: map()) -> {ok, state()} | {stop, term()}.
-callback handle_hook(adk_plugin:hook(), Context :: map(), Value :: term(),
                      state()) ->
    {ok, callback_result(), state()} |
    {stop, term(), state()}.
-callback terminate(Reason :: term(), state()) -> term().

-optional_callbacks([terminate/2]).
