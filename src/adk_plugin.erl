%% @doc Behaviour contract for ordered, Runner-scoped plugins.
%%
%% A plugin implements any subset of the lifecycle callbacks below. Every
%% callback receives the same immutable, secret-pruned context map, the value
%% at that point in the pipeline, and its private configuration. Observation
%% plugins should return `observe' (or `continue'). Intervention plugins may
%% additionally replace the value or halt the operation.
-module(adk_plugin).

-export([hooks/0, is_hook/1]).

-type hook() :: on_user_message | before_run | after_run |
                before_agent | after_agent |
                before_model | after_model | on_model_error |
                before_tool | after_tool | on_tool_error |
                on_event |
                on_error.
-type result() :: observe | continue | ok |
                  {replace, term()} | {halt, term()}.
-export_type([hook/0, result/0]).

-callback on_user_message(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback before_run(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback after_run(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback before_agent(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback after_agent(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback before_model(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback after_model(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback on_model_error(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback before_tool(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback after_tool(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback on_tool_error(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback on_event(Context :: map(), Value :: term(), Config :: map()) -> result().
-callback on_error(Context :: map(), Value :: term(), Config :: map()) -> result().

-optional_callbacks([
    on_user_message/3,
    before_run/3, after_run/3,
    before_agent/3, after_agent/3,
    before_model/3, after_model/3, on_model_error/3,
    before_tool/3, after_tool/3, on_tool_error/3,
    on_event/3,
    on_error/3
]).

-spec hooks() -> [hook()].
hooks() ->
    [on_user_message, before_run, after_run,
     before_agent, after_agent,
     before_model, after_model, on_model_error,
     before_tool, after_tool, on_tool_error,
     on_event,
     on_error].

%% @doc Validate a hook without converting user input to an atom.
-spec is_hook(term()) -> boolean().
is_hook(on_user_message) -> true;
is_hook(before_run) -> true;
is_hook(after_run) -> true;
is_hook(before_agent) -> true;
is_hook(after_agent) -> true;
is_hook(before_model) -> true;
is_hook(after_model) -> true;
is_hook(on_model_error) -> true;
is_hook(before_tool) -> true;
is_hook(after_tool) -> true;
is_hook(on_tool_error) -> true;
is_hook(on_event) -> true;
is_hook(on_error) -> true;
is_hook(_) -> false.
