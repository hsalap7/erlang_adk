%% @doc Bounded, supervised A2A 1.0 task store and execution coordinator.
%%
%% Protocol tasks are durable for a configured retention window while their
%% work runs as independent adk_task children.  The store retains only a
%% hash of the authenticated principal id.  Raw headers, credentials, and
%% principal terms are captured only by the short-lived execution closure and
%% are redacted before any result enters task history, artifacts, or events.
-module(adk_a2a_v1_server).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         send_message/3, send_message/4,
         get_task/3, send_result/4, list_tasks/3, cancel_task/3,
         create_push_config/3, get_push_config/3,
         list_push_configs/3, delete_push_config/3,
         subscribe/4, unsubscribe/3,
         progress/4, card/1, card_representation/1,
         extended_card/2, inspect_task/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_TIMEOUT, 60000).
-define(DEFAULT_RETENTION, 300000).
-define(DEFAULT_MAX_TASKS, 1000).
-define(DEFAULT_MAX_ACTIVE, 100).
-define(DEFAULT_MAX_EVENTS, 256).
-define(DEFAULT_MAX_SUBSCRIBERS, 64).
-define(DEFAULT_MAX_SUBSCRIBER_QUEUE, 8).
-define(MAX_SUBSCRIBER_QUEUE, 64).
-define(DEFAULT_MAX_INPUT_BYTES, 1048576).
-define(DEFAULT_MAX_MESSAGE_BYTES, 524288).
-define(DEFAULT_MAX_TASK_BYTES, 4194304).
-define(DEFAULT_MAX_EVENT_BYTES, 2097152).
-define(DEFAULT_MAX_ARTIFACT_BYTES, 2097152).
-define(DEFAULT_MAX_HISTORY_BYTES, 2097152).
-define(DEFAULT_MAX_HISTORY_MESSAGES, 128).
-define(DEFAULT_MAX_ARTIFACTS, 128).
-define(DEFAULT_MAX_PARTS_PER_ARTIFACT, 256).
-define(DEFAULT_MAX_PUSH_CONFIGS, 8).
-define(DEFAULT_MAX_PUSH_QUEUE, 128).
-define(MAX_PUSH_QUEUE, 1024).
-define(PUSH_WORKER_MAX_HEAP_WORDS, 500000).
-define(CALL_TIMEOUT_MS, 5000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(application:get_env(erlang_adk, a2a_v1_server_options, #{})).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?SERVER) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, [])
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => maps:get(name, Options, ?SERVER),
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec send_message(gen_server:server_ref(), map(), map()) ->
    {ok, map()} | {error, term()}.
send_message(Server, AuthContext, Params) ->
    send_message(Server, AuthContext, Params, undefined).

-spec send_message(gen_server:server_ref(), map(), map(), undefined | pid()) ->
    {ok, map()} | {error, term()}.
send_message(Server, AuthContext, Params, Subscriber) ->
    safe_call(Server, {send, AuthContext, Params, Subscriber}).

-spec get_task(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
get_task(Server, Scope, Params) ->
    gen_server:call(Server, {get, Scope, Params}).

%% @doc Resolve the response oneof for a blocking SendMessage call.  A direct
%% Message returned by the executor is intentionally transient; durable task
%% snapshots continue to contain only the protocol Task representation.
-spec send_result(gen_server:server_ref(), binary(), binary(),
                  undefined | non_neg_integer()) ->
    {ok, {task, map()} | {message, map()}} | {error, term()}.
send_result(Server, Scope, TaskId, HistoryLength) ->
    gen_server:call(Server,
                    {send_result, Scope, TaskId, HistoryLength}).

-spec list_tasks(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
list_tasks(Server, Scope, Params) ->
    gen_server:call(Server, {list, Scope, Params}).

-spec cancel_task(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
cancel_task(Server, Scope, Params) ->
    safe_call(Server, {cancel, Scope, Params}).

-spec create_push_config(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
create_push_config(Server, Scope, Params) ->
    safe_call(Server, {create_push_config, Scope, Params}).

-spec get_push_config(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
get_push_config(Server, Scope, Params) ->
    safe_call(Server, {get_push_config, Scope, Params}).

-spec list_push_configs(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
list_push_configs(Server, Scope, Params) ->
    safe_call(Server, {list_push_configs, Scope, Params}).

-spec delete_push_config(gen_server:server_ref(), binary(), map()) ->
    {ok, map()} | {error, term()}.
delete_push_config(Server, Scope, Params) ->
    safe_call(Server, {delete_push_config, Scope, Params}).

-spec subscribe(gen_server:server_ref(), binary(), map(), pid()) ->
    {ok, binary(), [{non_neg_integer(), map()}]} | {error, term()}.
subscribe(Server, Scope, Params, Subscriber) ->
    gen_server:call(Server, {subscribe, Scope, Params, Subscriber}).

-spec unsubscribe(gen_server:server_ref(), binary(), pid()) -> ok.
unsubscribe(Server, TaskId, Subscriber) ->
    gen_server:call(Server, {unsubscribe, TaskId, Subscriber}).

-spec progress(gen_server:server_ref(), binary(), binary(), term()) ->
    ok | {error, term()}.
progress(Server, TaskId, Scope, Event) ->
    safe_call(Server, {progress, TaskId, Scope, Event}).

-spec card(gen_server:server_ref()) -> {ok, map()}.
card(Server) -> gen_server:call(Server, card).

%% @doc Return the public card together with the time this server instance
%% installed the immutable representation.  HTTP bindings use the timestamp
%% for a stable Last-Modified validator while the card body supplies the ETag.
-spec card_representation(gen_server:server_ref()) ->
    {ok, map(), non_neg_integer()}.
card_representation(Server) -> gen_server:call(Server, card_representation).

-spec extended_card(gen_server:server_ref(), binary()) ->
    {ok, map()} | {error, term()}.
extended_card(Server, Scope) ->
    safe_call(Server, {extended_card, Scope}).

%% @doc Test/diagnostic view. It intentionally exposes only the public Task.
-spec inspect_task(gen_server:server_ref(), binary()) ->
    {ok, map()} | {error, not_found}.
inspect_task(Server, TaskId) ->
    gen_server:call(Server, {inspect, TaskId}).

init(Options) ->
    process_flag(trap_exit, true),
    case normalize_options(Options) of
        {ok, Config} ->
            case restore_task_snapshots(Config) of
                {ok, Tasks} ->
                    {ok, #{config => Config,
                           tasks => Tasks,
                           task_refs => #{},
                           subscriber_refs => #{},
                           push_secrets => #{},
                           push_active => #{},
                           push_queue => queue:new(),
                           card_last_modified =>
                               erlang:system_time(second),
                           cursor_secret => crypto:strong_rand_bytes(32)}};
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} -> {stop, Reason}
    end.

handle_call(card, _From, State) ->
    {reply, {ok, maps:get(card, maps:get(config, State))}, State};
handle_call(card_representation, _From, State) ->
    {reply, {ok, maps:get(card, maps:get(config, State)),
             maps:get(card_last_modified, State)}, State};
handle_call({extended_card, Scope}, _From, State)
  when is_binary(Scope), byte_size(Scope) =:= 32 ->
    Config = maps:get(config, State),
    Card = maps:get(card, Config),
    Capabilities = maps:get(<<"capabilities">>, Card, #{}),
    Reply = case maps:get(<<"extendedAgentCard">>, Capabilities, false) of
        false -> {error, unsupported_operation};
        true -> case maps:get(extended_card, Config, undefined) of
            undefined -> {error, extended_agent_card_not_configured};
            Extended -> {ok, Extended}
        end
    end,
    {reply, Reply, State};
handle_call({extended_card, _Scope}, _From, State) ->
    {reply, {error, invalid_auth_context}, State};
handle_call({send, AuthContext, Params, Subscriber}, _From, State0) ->
    State1 = prune(State0),
    case validate_send(AuthContext, Params, Subscriber, State1) of
        {ok, Input} ->
            case create_or_continue(Input, State1) of
                {ok, TaskId, Entry0, State2} ->
                    case maybe_attach_inline_push(
                           Input, TaskId, Entry0, State2) of
                        {ok, Entry1, State3} ->
                            send_started_reply(Input, Params, Subscriber,
                                               TaskId, Entry1, State3);
                        {error, Reason, State3} ->
                            {reply, {error, Reason}, State3}
                    end;
                {error, Reason, State2} ->
                    {reply, {error, Reason}, State2}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State1}
    end;
handle_call({get, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    Reply = case validate_get_params(Params) of
        {ok, TaskId, HistoryLength} ->
            case visible_entry(TaskId, Scope, State1) of
                {ok, Entry} ->
                    {ok, public_task(maps:get(task, Entry),
                                     HistoryLength, true)};
                error -> {error, task_not_found}
            end;
        {error, _} = Error -> Error
    end,
    {reply, Reply, State1};
handle_call({send_result, Scope, TaskId, HistoryLength}, _From, State0) ->
    State1 = prune(State0),
    Reply = case visible_entry(TaskId, Scope, State1) of
        {ok, #{direct_message := Message}} when is_map(Message) ->
            {ok, {message, Message}};
        {ok, Entry} ->
            {ok, {task, public_task(maps:get(task, Entry),
                                    HistoryLength, true)}};
        error -> {error, task_not_found}
    end,
    {reply, Reply, State1};
handle_call({list, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    {reply, list_visible(Scope, Params, State1), State1};
handle_call({cancel, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    case required_id(Params) of
        {ok, TaskId} ->
            case visible_entry(TaskId, Scope, State1) of
                error -> {reply, {error, task_not_found}, State1};
                {ok, Entry} -> cancel_entry(Entry, State1)
            end;
        {error, _} = Error -> {reply, Error, State1}
    end;
handle_call({create_push_config, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    case create_push_configuration(Scope, Params, State1) of
        {ok, Public, State2} -> {reply, {ok, Public}, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({get_push_config, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    {reply, get_push_configuration(Scope, Params, State1), State1};
handle_call({list_push_configs, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    {reply, list_push_configurations(Scope, Params, State1), State1};
handle_call({delete_push_config, Scope, Params}, _From, State0) ->
    State1 = prune(State0),
    case delete_push_configuration(Scope, Params, State1) of
        {ok, State2} -> {reply, {ok, #{}}, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({subscribe, Scope, Params, Subscriber}, _From, State0)
  when is_pid(Subscriber) ->
    State1 = prune(State0),
    case subscribe_input(Params) of
        {ok, TaskId, Cursor} ->
            case visible_entry(TaskId, Scope, State1) of
                error -> {reply, {error, task_not_found}, State1};
                {ok, Entry0} ->
                    Task = maps:get(task, Entry0),
                    case task_terminal(Task) of
                        true ->
                            {reply, {error, unsupported_terminal_subscription},
                             State1};
                        false ->
                            case replay_available(Entry0, Cursor) of
                                false ->
                                    {reply, {error, replay_window_exceeded},
                                     State1};
                                true ->
                                    case add_subscriber(Subscriber, Entry0,
                                                        State1) of
                                        {ok, Entry1, State2} ->
                                            Frames = replay_frames(Entry1,
                                                                   Cursor),
                                            {reply, {ok, TaskId, Frames},
                                             put_entry(Entry1, State2)};
                                        {error, subscriber_capacity} ->
                                            {reply,
                                             {error, subscriber_capacity},
                                             State1}
                                    end
                            end
                    end
            end;
        {error, _} = Error -> {reply, Error, State1}
    end;
handle_call({subscribe, _Scope, _Params, _Subscriber}, _From, State) ->
    {reply, {error, invalid_subscriber}, State};
handle_call({unsubscribe, TaskId, Subscriber}, _From, State0) ->
    {State1, _Removed} = remove_subscriber(TaskId, Subscriber, State0),
    {reply, ok, State1};
handle_call({progress, TaskId, Scope, Event}, _From, State0) ->
    case visible_entry(TaskId, Scope, State0) of
        {ok, Entry0} ->
            case task_terminal(maps:get(task, Entry0)) of
                true -> {reply, {error, task_terminal}, State0};
                false ->
                    case apply_progress(Event, Entry0, State0) of
                        {ok, Entry1, State1} ->
                            {reply, ok, put_entry(Entry1, State1)};
                        {error, Reason} ->
                            {reply, {error, Reason}, State0}
                    end
            end;
        error -> {reply, {error, task_not_found}, State0}
    end;
handle_call({inspect, TaskId}, _From, State) ->
    Reply = case maps:find(TaskId, maps:get(tasks, State)) of
        {ok, Entry} -> {ok, public_task(maps:get(task, Entry), undefined,
                                        true)};
        error -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({adk_task_terminal, TaskRef, Outcome}, State0) ->
    case maps:take(TaskRef, maps:get(task_refs, State0)) of
        {TaskId, RemainingRefs} ->
            State1 = State0#{task_refs => RemainingRefs},
            case maps:find(TaskId, maps:get(tasks, State1)) of
                {ok, Entry = #{task_ref := TaskRef}} ->
                    {Entry1, State2} = finalize_outcome(
                                         Outcome,
                                         Entry#{task_ref => undefined},
                                         State1),
                    {noreply, put_entry(Entry1, State2)};
                _ -> {noreply, State1}
            end;
        error -> {noreply, State0}
    end;
handle_info({a2a_push_delivery_done, Pid, DeliveryRef}, State0) ->
    case take_push_worker(Pid, DeliveryRef, State0) of
        {ok, State1} -> {noreply, start_queued_push(State1)};
        error -> {noreply, State0}
    end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State0) ->
    case maps:take(Ref, maps:get(subscriber_refs, State0)) of
        {{TaskId, Subscriber}, Remaining} ->
            State1 = State0#{subscriber_refs => Remaining},
            {State2, _} = remove_subscriber_ref(
                            TaskId, Subscriber, Ref, State1),
            {noreply, State2};
        error ->
            case maps:take(Ref, maps:get(push_active, State0)) of
                {_Worker, RemainingPush} ->
                    {noreply, start_queued_push(
                                State0#{push_active => RemainingPush})};
                error -> {noreply, State0}
            end
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Id, Entry) ->
          case maps:get(task_ref, Entry, undefined) of
              Ref when is_binary(Ref) ->
                  _ = catch adk_task:cancel(Ref, server_stopping);
              _ -> ok
          end
      end, maps:get(tasks, State, #{})),
    maps:foreach(
      fun(_Ref, #{pid := Pid}) ->
          _ = catch exit(Pid, kill),
          ok
      end,
      maps:get(push_active, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

safe_call(Server, Request) ->
    try gen_server:call(Server, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, server_unavailable};
        exit:{noproc, _} -> {error, server_unavailable};
        exit:{normal, _} -> {error, server_unavailable};
        exit:{shutdown, _} -> {error, server_unavailable};
        exit:_ -> {error, server_unavailable}
    end.

%% option validation

normalize_options(Options) ->
    Card0 = maps:get(card, Options,
                     application:get_env(erlang_adk, a2a_v1_card, undefined)),
    Executor = maps:get(executor, Options,
                        application:get_env(
                          erlang_adk, a2a_v1_executor,
                          {adk_a2a_v1_agent_executor, execute})),
    ExtendedCard0 = maps:get(
                      extended_card, Options,
                      application:get_env(erlang_adk,
                                          a2a_v1_extended_card, undefined)),
    PushPolicy0 = maps:get(push_policy, Options, #{}),
    Config0 = #{card => Card0,
                extended_card => ExtendedCard0,
                executor => Executor,
                task_timeout => maps:get(task_timeout, Options,
                                         ?DEFAULT_TIMEOUT),
                retention_ms => maps:get(retention_ms, Options,
                                         ?DEFAULT_RETENTION),
                max_tasks => maps:get(max_tasks, Options,
                                      ?DEFAULT_MAX_TASKS),
                max_active => maps:get(max_active, Options,
                                       ?DEFAULT_MAX_ACTIVE),
                max_events => maps:get(max_events, Options,
                                       ?DEFAULT_MAX_EVENTS),
                max_subscribers_per_task => maps:get(
                                              max_subscribers_per_task,
                                              Options,
                                              ?DEFAULT_MAX_SUBSCRIBERS),
                max_subscriber_queue => maps:get(
                                          max_subscriber_queue, Options,
                                          ?DEFAULT_MAX_SUBSCRIBER_QUEUE),
                max_input_bytes => maps:get(max_input_bytes, Options,
                                             ?DEFAULT_MAX_INPUT_BYTES),
                max_message_bytes => maps:get(max_message_bytes, Options,
                                               ?DEFAULT_MAX_MESSAGE_BYTES),
                max_task_bytes => maps:get(max_task_bytes, Options,
                                            ?DEFAULT_MAX_TASK_BYTES),
                max_event_bytes => maps:get(max_event_bytes, Options,
                                             ?DEFAULT_MAX_EVENT_BYTES),
                max_artifact_bytes => maps:get(max_artifact_bytes, Options,
                                                ?DEFAULT_MAX_ARTIFACT_BYTES),
                max_history_bytes => maps:get(max_history_bytes, Options,
                                               ?DEFAULT_MAX_HISTORY_BYTES),
                max_history_messages => maps:get(
                                          max_history_messages, Options,
                                          ?DEFAULT_MAX_HISTORY_MESSAGES),
                max_artifacts => maps:get(max_artifacts, Options,
                                           ?DEFAULT_MAX_ARTIFACTS),
                max_parts_per_artifact => maps:get(
                                            max_parts_per_artifact, Options,
                                            ?DEFAULT_MAX_PARTS_PER_ARTIFACT),
                max_push_configs_per_task => maps:get(
                                               max_push_configs_per_task,
                                               Options,
                                               ?DEFAULT_MAX_PUSH_CONFIGS),
                max_push_queue => maps:get(max_push_queue, Options,
                                            ?DEFAULT_MAX_PUSH_QUEUE),
                task_store => maps:get(task_store, Options, undefined)},
    case {adk_a2a_v1_card:validate(Card0), valid_executor(Executor),
          valid_config_numbers(Config0),
          validate_extended_card(ExtendedCard0),
          adk_a2a_v1_push:normalize_policy(PushPolicy0),
          adk_a2a_v1_task_store:validate_descriptor(
            maps:get(task_store, Config0))} of
        {{ok, Card}, true, true, {ok, ExtendedCard}, {ok, PushPolicy},
         {ok, TaskStore}} ->
            {ok, Interface} = adk_a2a_v1_card:jsonrpc_interface(Card),
            {ok, Config0#{card => Card,
                          extended_card => ExtendedCard,
                          push_policy => PushPolicy,
                          task_store => TaskStore,
                          tenant => maps:get(<<"tenant">>, Interface,
                                             undefined)}};
        {{error, Reason}, _, _, _, _, _} ->
            {error, {invalid_a2a_v1_card, Reason}};
        {_, false, _, _, _, _} -> {error, invalid_a2a_v1_executor};
        {_, _, _, {error, Reason}, _, _} ->
            {error, {invalid_a2a_v1_extended_card, Reason}};
        {_, _, _, _, {error, _}, _} ->
            {error, invalid_a2a_v1_push_policy};
        {_, _, _, _, _, {error, _}} ->
            {error, invalid_a2a_v1_task_store};
        _ -> {error, invalid_a2a_v1_server_options}
    end.

validate_extended_card(undefined) -> {ok, undefined};
validate_extended_card(Card) -> adk_a2a_v1_card:validate(Card).

valid_executor(Fun) when is_function(Fun, 2) -> true;
valid_executor({Module, Function}) -> is_atom(Module) andalso is_atom(Function);
valid_executor(_) -> false.

valid_config_numbers(Config) ->
    lists:all(fun positive_integer/1,
              [maps:get(task_timeout, Config),
               maps:get(retention_ms, Config),
               maps:get(max_tasks, Config),
               maps:get(max_active, Config),
               maps:get(max_events, Config),
               maps:get(max_subscribers_per_task, Config),
               maps:get(max_subscriber_queue, Config),
               maps:get(max_input_bytes, Config),
               maps:get(max_message_bytes, Config),
               maps:get(max_task_bytes, Config),
               maps:get(max_event_bytes, Config),
               maps:get(max_artifact_bytes, Config),
               maps:get(max_history_bytes, Config),
               maps:get(max_history_messages, Config),
               maps:get(max_artifacts, Config),
               maps:get(max_parts_per_artifact, Config),
               maps:get(max_push_configs_per_task, Config),
               maps:get(max_push_queue, Config)])
    andalso valid_payload_limit_maxima(Config).

valid_payload_limit_maxima(Config) ->
    maps:get(max_input_bytes, Config) >= 1024
    andalso maps:get(max_message_bytes, Config) >= 256
    andalso maps:get(max_task_bytes, Config) >= 4096
    andalso maps:get(max_event_bytes, Config) >= 1024
    andalso maps:get(max_artifact_bytes, Config) >= 512
    andalso maps:get(max_history_bytes, Config) >= 512
    andalso maps:get(max_input_bytes, Config) =< ?DEFAULT_MAX_INPUT_BYTES
    andalso maps:get(max_message_bytes, Config) =< ?DEFAULT_MAX_MESSAGE_BYTES
    andalso maps:get(max_task_bytes, Config) =< ?DEFAULT_MAX_TASK_BYTES
    andalso maps:get(max_event_bytes, Config) =< ?DEFAULT_MAX_EVENT_BYTES
    andalso maps:get(max_artifact_bytes, Config) =<
                ?DEFAULT_MAX_ARTIFACT_BYTES
    andalso maps:get(max_history_bytes, Config) =<
                ?DEFAULT_MAX_HISTORY_BYTES
    andalso maps:get(max_history_messages, Config) =<
                ?DEFAULT_MAX_HISTORY_MESSAGES
    andalso maps:get(max_subscriber_queue, Config) =<
                ?MAX_SUBSCRIBER_QUEUE
    andalso maps:get(max_artifacts, Config) =< ?DEFAULT_MAX_ARTIFACTS
    andalso maps:get(max_parts_per_artifact, Config) =<
                ?DEFAULT_MAX_PARTS_PER_ARTIFACT
    andalso maps:get(max_push_configs_per_task, Config) =<
                ?DEFAULT_MAX_PUSH_CONFIGS
    andalso maps:get(max_push_queue, Config) =< ?MAX_PUSH_QUEUE.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

input_payload_allowed(Message, Params, State) ->
    Config = maps:get(config, State),
    SafeParams = Params#{<<"message">> => Message},
    within_json_bytes(SafeParams, maps:get(max_input_bytes, Config))
    andalso within_json_bytes(Message, maps:get(max_message_bytes, Config)).

retained_task_allowed(Task, Config) ->
    History = maps:get(<<"history">>, Task, []),
    Artifacts = maps:get(<<"artifacts">>, Task, []),
    is_list(History) andalso is_list(Artifacts)
    andalso length(History) =< maps:get(max_history_messages, Config)
    andalso length(Artifacts) =< maps:get(max_artifacts, Config)
    andalso within_json_bytes(History, maps:get(max_history_bytes, Config))
    andalso lists:all(
              fun(Message) ->
                  within_json_bytes(
                    Message, maps:get(max_message_bytes, Config))
              end, History)
    andalso lists:all(fun(Artifact) -> artifact_allowed(Artifact, Config) end,
                      Artifacts)
    andalso within_json_bytes(Task, maps:get(max_task_bytes, Config)).

artifact_allowed(Artifact, Config) ->
    Parts = maps:get(<<"parts">>, Artifact, invalid),
    is_list(Parts)
    andalso length(Parts) =< maps:get(max_parts_per_artifact, Config)
    andalso within_json_bytes(Artifact,
                              maps:get(max_artifact_bytes, Config)).

event_payload_allowed(Payload, Config) ->
    within_json_bytes(Payload, maps:get(max_event_bytes, Config)).

status_change_allowed(Task, State) ->
    Config = maps:get(config, State),
    Payload = #{<<"statusUpdate">> =>
                    #{<<"taskId">> => maps:get(<<"id">>, Task),
                      <<"contextId">> => maps:get(<<"contextId">>, Task),
                      <<"status">> => maps:get(<<"status">>, Task)}},
    retained_task_allowed(Task, Config)
    andalso event_payload_allowed(Payload, Config).

within_json_bytes(Value, Max) ->
    try jsx:encode(Value) of
        Encoded when is_binary(Encoded) -> byte_size(Encoded) =< Max
    catch _:_ -> false
    end.

%% send and execution

validate_send(Auth, Params, Subscriber, State)
  when is_map(Auth), is_map(Params),
       (Subscriber =:= undefined orelse is_pid(Subscriber)) ->
    case {maps:find(scope, Auth), maps:find(principal, Auth),
          maps:find(secret_seeds, Auth), maps:find(<<"message">>, Params)} of
        {{ok, Scope}, {ok, Principal}, {ok, Seeds}, {ok, Message0}}
          when is_binary(Scope), is_list(Seeds) ->
            Sanitized = adk_secret_redactor:redact(Message0, Seeds),
            case adk_a2a_v1_codec:validate_message(Sanitized) of
                {ok, Message} ->
                    case maps:get(<<"role">>, Message) of
                        <<"ROLE_USER">> ->
                            case input_payload_allowed(Message, Params,
                                                       State) of
                                false -> {error, a2a_input_payload_too_large};
                                true ->
                                    case validate_send_config(Params) of
                                        ok ->
                                            case validate_inline_push_config(
                                                   Params, State) of
                                                ok ->
                                                    case tenant_matches(
                                                           Params, State) of
                                                        true ->
                                                            {ok, #{
                                                              scope => Scope,
                                                              principal =>
                                                                Principal,
                                                              seeds => Seeds,
                                                              message => Message,
                                                              params => Params}};
                                                        false ->
                                                            {error,
                                                             invalid_tenant}
                                                    end;
                                                {error, _} = Error -> Error
                                            end;
                                        Error -> Error
                                    end
                            end;
                        _ -> {error, invalid_user_message_role}
                    end;
                {error, Reason} -> {error, {invalid_message, Reason}}
            end;
        _ -> {error, invalid_auth_context}
    end;
validate_send(_, _, _, _) -> {error, invalid_send_message_request}.

validate_send_config(Params) ->
    case maps:get(<<"configuration">>, Params, #{}) of
        Config when is_map(Config) ->
            Return = maps:get(<<"returnImmediately">>, Config, false),
            History = maps:get(<<"historyLength">>, Config, undefined),
            Modes = maps:get(<<"acceptedOutputModes">>, Config, []),
            Push = maps:get(<<"taskPushNotificationConfig">>, Config,
                            undefined),
            case is_boolean(Return) andalso valid_optional_nonneg(History)
                 andalso is_list(Modes)
                 andalso lists:all(fun is_binary/1, Modes)
                 andalso (Push =:= undefined orelse is_map(Push)) of
                true -> ok;
                false -> {error, invalid_send_configuration}
            end;
        _ -> {error, invalid_send_configuration}
    end.

validate_inline_push_config(Params, State) ->
    Configuration = maps:get(<<"configuration">>, Params, #{}),
    case maps:get(<<"taskPushNotificationConfig">>, Configuration,
                  undefined) of
        undefined -> ok;
        Push when is_map(Push) ->
            case push_capability(State) of
                false -> {error, push_notification_not_supported};
                true ->
                    Config = maps:get(config, State),
                    Id = case maps:get(<<"id">>, Push, <<>>) of
                        <<>> -> <<"push-validation">>;
                        Value -> Value
                    end,
                    case adk_a2a_v1_push:prepare_config(
                           <<"task-validation">>, Id,
                           maps:get(tenant, Config), Push,
                           maps:get(push_policy, Config)) of
                        {ok, _Public, _Secret} -> ok;
                        {error, _} = Error -> Error
                    end
            end
    end.

tenant_matches(Params, State) ->
    Expected = maps:get(tenant, maps:get(config, State)),
    Actual = maps:get(<<"tenant">>, Params, undefined),
    case Expected of
        undefined -> Actual =:= undefined orelse Actual =:= <<>>;
        _ -> Actual =:= Expected
    end.

create_or_continue(Input, State) ->
    Message = maps:get(message, Input),
    case maps:find(<<"taskId">>, Message) of
        error -> create_task(Input, State);
        {ok, TaskId} -> continue_task(TaskId, Input, State)
    end.

create_task(Input, State) ->
    case active_count(State) >= maps:get(max_active, maps:get(config, State)) of
        true -> {error, server_capacity_reached, State};
        false ->
            case ensure_task_capacity(State) of
                {error, capacity, State1} ->
                    {error, server_capacity_reached, State1};
                {ok, State1} ->
                    TaskId = uuid(<<"task-">>),
                    Message0 = maps:get(message, Input),
                    ContextId = maps:get(<<"contextId">>, Message0,
                                         uuid(<<"context-">>)),
                    Message = Message0#{<<"contextId">> => ContextId,
                                        <<"taskId">> => TaskId},
                    Status = status(<<"TASK_STATE_SUBMITTED">>, undefined),
                    Task = #{<<"id">> => TaskId,
                             <<"contextId">> => ContextId,
                             <<"status">> => Status,
                             <<"artifacts">> => [],
                             <<"history">> => [Message]},
                    Config = maps:get(config, State1),
                    case retained_task_allowed(Task, Config)
                         andalso event_payload_allowed(
                                   #{<<"task">> => Task}, Config) of
                        false ->
                            {error, a2a_task_payload_limit_exceeded, State1};
                        true ->
                            Now = erlang:system_time(millisecond),
                            Entry0 = #{id => TaskId,
                                       scope => maps:get(scope, Input),
                                       task => Task,
                                       task_ref => undefined,
                                       direct_message => undefined,
                                       events => [], next_seq => 1,
                                       subscribers => #{},
                                       updated_ms => Now,
                                       terminal_at => undefined},
                            {Entry1, State2} = append_event(
                                                 #{<<"task">> => Task}, false,
                                                 Entry0, State1),
                            {ok, TaskId, Entry1,
                             put_entry(Entry1, State2)}
                    end
            end
    end.

continue_task(TaskId, Input, State) ->
    Scope = maps:get(scope, Input),
    case visible_entry(TaskId, Scope, State) of
        error -> {error, task_not_found, State};
        {ok, Entry0} ->
            Task0 = maps:get(task, Entry0),
            Current = task_state(Task0),
            case adk_a2a_v1_codec:terminal_state(Current) orelse
                 maps:get(task_ref, Entry0, undefined) =/= undefined of
                true -> {error, task_not_accepting_messages, State};
                false ->
                    Message0 = maps:get(message, Input),
                    ContextId = maps:get(<<"contextId">>, Task0),
                    case maps:get(<<"contextId">>, Message0, ContextId) of
                        ContextId ->
                            Message = Message0#{<<"contextId">> => ContextId,
                                                <<"taskId">> => TaskId},
                            History = maps:get(<<"history">>, Task0, []),
                            Task1 = Task0#{<<"history">> => History ++ [Message],
                                           <<"status">> => status(
                                             <<"TASK_STATE_SUBMITTED">>,
                                             undefined)},
                            case retained_task_allowed(
                                   Task1, maps:get(config, State)) of
                                false ->
                                    {error, a2a_task_payload_limit_exceeded,
                                     State};
                                true ->
                                    {Entry1, State1} = status_event(
                                                         Task1, Entry0,
                                                         State),
                                    {ok, TaskId, Entry1,
                                     put_entry(Entry1, State1)}
                            end;
                        _ -> {error, context_id_mismatch, State}
                    end
            end
    end.

start_execution(Input, TaskId, Entry0, State0) ->
    Server = self(),
    Scope = maps:get(scope, Input),
    Seeds = maps:get(seeds, Input),
    Principal = maps:get(principal, Input),
    Config = maps:get(config, State0),
    Executor = maps:get(executor, Config),
    Message = lists:last(maps:get(<<"history">>, maps:get(task, Entry0))),
    Metadata0 = maps:get(<<"metadata">>, maps:get(params, Input), #{}),
    Metadata = adk_secret_redactor:redact(Metadata0, Seeds),
    Request = #{task_id => TaskId,
                context_id => maps:get(<<"contextId">>, maps:get(task, Entry0)),
                message => Message,
                metadata => Metadata,
                principal => Principal,
                %% The opaque authenticated scope is safe to use as the
                %% Runner user identity; raw principal terms are not retained.
                scope => Scope,
                continuation =>
                    length(maps:get(<<"history">>, maps:get(task, Entry0))) > 1},
    Emit = fun(Event0) ->
        Event = adk_secret_redactor:redact(Event0, Seeds),
        progress(Server, TaskId, Scope, Event)
    end,
    Work = fun() ->
        Result0 = invoke_executor(Executor, Request, Emit),
        adk_secret_redactor:redact(Result0, Seeds)
    end,
    TaskOptions = #{timeout => maps:get(task_timeout, Config),
                    %% The work closure may hold a transient authenticated
                    %% principal. Expire it immediately after its redacted
                    %% outcome has been delivered to this protocol store.
                    retention_ms => 0,
                    notify => Server},
    case adk_task:start(Work, TaskOptions) of
        {ok, TaskRef} ->
            TaskRefs = maps:get(task_refs, State0),
            Entry1 = Entry0#{task_ref => TaskRef},
            Task1 = set_status(maps:get(task, Entry1),
                               <<"TASK_STATE_WORKING">>, undefined),
            {Entry2, State1} = status_event(Task1, Entry1,
                                            State0#{task_refs =>
                                                      TaskRefs#{TaskRef =>
                                                                  TaskId}}),
            {ok, Entry2, State1};
        {error, Reason} ->
            Task1 = set_status(maps:get(task, Entry0),
                               <<"TASK_STATE_FAILED">>,
                               agent_message(Entry0,
                                             <<"Task execution could not start">>)),
            {Entry1, State1} = terminal_status_event(Task1, Entry0, State0),
            {error, Reason, Entry1, State1}
    end.

send_started_reply(Input, Params, Subscriber, TaskId, Entry0, State0) ->
    case start_execution(Input, TaskId, Entry0, State0) of
        {ok, Entry1, State1} ->
            case maybe_subscribe(Subscriber, Entry1, State1) of
                {ok, Entry2, State2} ->
                    Task = public_task(maps:get(task, Entry2),
                                       send_history_length(Params), true),
                    Frames = replay_frames(Entry2, 0),
                    Reply = #{task_id => TaskId, task => Task,
                              frames => Frames},
                    {reply, {ok, Reply}, put_entry(Entry2, State2)};
                {error, subscriber_capacity} ->
                    {reply, {error, subscriber_capacity},
                     put_entry(Entry1, State1)}
            end;
        {error, Reason, FailedEntry, State1} ->
            case maybe_subscribe(Subscriber, FailedEntry, State1) of
                {ok, FailedEntry1, State2} ->
                    Reply = #{task_id => TaskId,
                              task => public_task(
                                        maps:get(task, FailedEntry1),
                                        send_history_length(Params), true),
                              frames => replay_frames(FailedEntry1, 0)},
                    {reply,
                     {error, {execution_start_failed, Reason, Reply}},
                     put_entry(FailedEntry1, State2)};
                {error, subscriber_capacity} ->
                    {reply, {error, subscriber_capacity},
                     put_entry(FailedEntry, State1)}
            end
    end.

invoke_executor(Fun, Request, Emit) when is_function(Fun, 2) ->
    Fun(Request, Emit);
invoke_executor({Module, Function}, Request, Emit) ->
    apply(Module, Function, [Request, Emit]).

%% push-notification configuration

maybe_attach_inline_push(Input, TaskId, Entry, State) ->
    Configuration = maps:get(<<"configuration">>, maps:get(params, Input),
                             #{}),
    case maps:get(<<"taskPushNotificationConfig">>, Configuration,
                  undefined) of
        undefined -> {ok, Entry, State};
        Config when is_map(Config) ->
            case push_capability(State) of
                false -> {error, push_notification_not_supported, State};
                true ->
                    case attach_push_configuration(
                           TaskId, Config, Entry, State) of
                        {ok, _Public, State1} ->
                            {ok, maps:get(TaskId, maps:get(tasks, State1)),
                             State1};
                        {error, Reason, State1} ->
                            {error, Reason, State1}
                    end
            end;
        _ -> {error, invalid_push_notification_config, State}
    end.

create_push_configuration(Scope, Params, State) when is_map(Params) ->
    case push_capability(State) of
        false -> {error, push_notification_not_supported, State};
        true ->
            case required_push_task_id(Params) of
                {ok, TaskId} ->
                    case tenant_matches(Params, State) of
                        false -> {error, invalid_tenant, State};
                        true ->
                            case visible_entry(TaskId, Scope, State) of
                                error -> {error, task_not_found, State};
                                {ok, Entry} ->
                                    attach_push_configuration(
                                      TaskId, Params, Entry, State)
                            end
                    end;
                {error, Reason} -> {error, Reason, State}
            end
    end;
create_push_configuration(_Scope, _Params, State) ->
    {error, invalid_push_notification_config, State}.

attach_push_configuration(TaskId, Config0, Entry0, State0) ->
    Configs0 = maps:get(push_configs, Entry0, #{}),
    Maximum = maps:get(max_push_configs_per_task, maps:get(config, State0)),
    ConfigId = case maps:get(<<"id">>, Config0, <<>>) of
        <<>> -> uuid(<<"push-">>);
        Value -> Value
    end,
    case map_size(Configs0) >= Maximum orelse maps:is_key(ConfigId, Configs0) of
        true -> {error, push_notification_capacity_reached, State0};
        false ->
            ServerConfig = maps:get(config, State0),
            Tenant = maps:get(tenant, ServerConfig),
            Policy = maps:get(push_policy, ServerConfig),
            case adk_a2a_v1_push:prepare_config(
                   TaskId, ConfigId, Tenant, Config0, Policy) of
                {ok, Public, Secret} ->
                    Entry1 = Entry0#{push_configs =>
                                        Configs0#{ConfigId => Public}},
                    Secrets0 = maps:get(push_secrets, State0),
                    State1 = State0#{push_secrets =>
                                        Secrets0#{{TaskId, ConfigId} => Secret}},
                    {ok, Public, put_entry(Entry1, State1)};
                {error, Reason} -> {error, Reason, State0}
            end
    end.

get_push_configuration(Scope, Params, State) ->
    case push_capability(State) of
        false -> {error, push_notification_not_supported};
        true -> get_push_configuration_enabled(Scope, Params, State)
    end.

get_push_configuration_enabled(Scope, Params, State) ->
    case tenant_matches(Params, State) of
        false -> {error, invalid_tenant};
        true -> get_push_configuration_tenant(Scope, Params, State)
    end.

get_push_configuration_tenant(Scope, Params, State) ->
    case push_lookup_input(Params) of
        {ok, TaskId, ConfigId} ->
            case visible_entry(TaskId, Scope, State) of
                {ok, Entry} ->
                    case maps:find(ConfigId,
                                   maps:get(push_configs, Entry, #{})) of
                        {ok, Public} -> {ok, Public};
                        error -> {error, task_not_found}
                    end;
                error -> {error, task_not_found}
            end;
        {error, _} = Error -> Error
    end.

list_push_configurations(Scope, Params, State) when is_map(Params) ->
    case push_capability(State) of
        false -> {error, push_notification_not_supported};
        true -> list_push_configurations_enabled(Scope, Params, State)
    end;
list_push_configurations(_Scope, _Params, _State) ->
    {error, invalid_params}.

list_push_configurations_enabled(Scope, Params, State) ->
    case tenant_matches(Params, State) of
        false -> {error, invalid_tenant};
        true -> list_push_configurations_tenant(Scope, Params, State)
    end.

list_push_configurations_tenant(Scope, Params, State) ->
    case required_push_task_id(Params) of
        {ok, TaskId} ->
            case visible_entry(TaskId, Scope, State) of
                {ok, Entry} ->
                    list_entry_push_configs(Params, Entry);
                error -> {error, task_not_found}
            end;
        {error, _} = Error -> Error
    end.

list_entry_push_configs(Params, Entry) ->
    PageSize = maps:get(<<"pageSize">>, Params, 50),
    Token = maps:get(<<"pageToken">>, Params, <<>>),
    case is_integer(PageSize) andalso PageSize >= 1 andalso PageSize =< 100
         andalso is_binary(Token) of
        false -> {error, invalid_push_notification_list_params};
        true ->
            Sorted = lists:keysort(
                       1, maps:to_list(maps:get(push_configs, Entry, #{}))),
            case push_after_token(Sorted, Token) of
                {ok, Remaining} ->
                    {Page, Tail} = split_at(Remaining, PageSize),
                    Next = case {Page, Tail} of
                        {[], _} -> <<>>;
                        {_, []} -> <<>>;
                        {_, _} -> element(1, lists:last(Page))
                    end,
                    {ok, #{<<"configs">> => [Config || {_Id, Config} <- Page],
                           <<"nextPageToken">> => Next}};
                error -> {error, invalid_page_token}
            end
    end.

push_after_token(Configs, <<>>) -> {ok, Configs};
push_after_token([], _Token) -> error;
push_after_token([{Token, _} | Rest], Token) -> {ok, Rest};
push_after_token([_ | Rest], Token) -> push_after_token(Rest, Token).

delete_push_configuration(Scope, Params, State0) ->
    case push_capability(State0) of
        false -> {error, push_notification_not_supported, State0};
        true ->
            case tenant_matches(Params, State0) of
                false -> {error, invalid_tenant, State0};
                true -> delete_push_configuration_tenant(
                          Scope, Params, State0)
            end
    end.

delete_push_configuration_tenant(Scope, Params, State0) ->
    case push_lookup_input(Params) of
                {ok, TaskId, ConfigId} ->
                    case visible_entry(TaskId, Scope, State0) of
                        error -> {error, task_not_found, State0};
                        {ok, Entry0} ->
                            Configs = maps:remove(
                                        ConfigId,
                                        maps:get(push_configs, Entry0, #{})),
                            Entry1 = Entry0#{push_configs => Configs},
                            Secrets = maps:remove(
                                        {TaskId, ConfigId},
                                        maps:get(push_secrets, State0)),
                            State1 = put_entry(
                                       Entry1,
                                       State0#{push_secrets => Secrets}),
                            {ok, cancel_push_key(
                                   {TaskId, ConfigId}, State1)}
                    end;
        {error, Reason} -> {error, Reason, State0}
    end.

required_push_task_id(Params) when is_map(Params) ->
    case maps:get(<<"taskId">>, Params, undefined) of
        Id when is_binary(Id), byte_size(Id) > 0 -> {ok, Id};
        _ -> {error, invalid_task_id}
    end.

push_lookup_input(Params) ->
    case {required_push_task_id(Params),
          maps:get(<<"id">>, Params, undefined)} of
        {{ok, TaskId}, ConfigId}
          when is_binary(ConfigId), byte_size(ConfigId) > 0 ->
            {ok, TaskId, ConfigId};
        {{error, _} = Error, _} -> Error;
        _ -> {error, invalid_push_notification_config_id}
    end.

push_capability(State) ->
    Card = maps:get(card, maps:get(config, State)),
    maps:get(<<"pushNotifications">>,
             maps:get(<<"capabilities">>, Card, #{}), false).

%% progress and terminal outcomes

apply_progress({status, StateName, Message0}, Entry0, State0)
  when is_binary(StateName) ->
    case valid_progress_state(StateName) of
        true ->
            Message = normalize_agent_message(Message0, Entry0),
            Task1 = set_status(maps:get(task, Entry0), StateName, Message),
            case status_change_allowed(Task1, State0) of
                false -> {error, a2a_task_payload_limit_exceeded};
                true ->
                    case adk_a2a_v1_codec:terminal_state(StateName) of
                        true ->
                            {Entry1, State1} = terminal_status_event(
                                                 Task1, Entry0, State0),
                            {ok, Entry1, State1};
                        false ->
                            {Entry1, State1} = status_event(
                                                 Task1, Entry0, State0),
                            {ok, Entry1, State1}
                    end
            end;
        false -> {error, invalid_progress_state}
    end;
apply_progress({artifact, Artifact0, Append, LastChunk}, Entry0, State0)
  when is_boolean(Append), is_boolean(LastChunk) ->
    case adk_a2a_v1_codec:validate_artifact(Artifact0) of
        {ok, Artifact} ->
            Task0 = maps:get(task, Entry0),
            Task1 = merge_artifact(Task0, Artifact, Append),
            Update = #{<<"taskId">> => maps:get(<<"id">>, Task0),
                       <<"contextId">> => maps:get(<<"contextId">>, Task0),
                       <<"artifact">> => Artifact,
                       <<"append">> => Append,
                       <<"lastChunk">> => LastChunk},
            Config = maps:get(config, State0),
            Payload = #{<<"artifactUpdate">> => Update},
            case artifact_allowed(Artifact, Config)
                 andalso retained_task_allowed(Task1, Config)
                 andalso event_payload_allowed(Payload, Config) of
                false -> {error, a2a_task_payload_limit_exceeded};
                true ->
                    Entry1 = Entry0#{task => Task1},
                    {Entry2, State1} = append_event(
                                         Payload, false, Entry1, State0),
                    {ok, Entry2, State1}
            end;
        {error, Reason} -> {error, Reason}
    end;
apply_progress(_, _Entry, _State) -> {error, invalid_progress_event}.

valid_progress_state(<<"TASK_STATE_WORKING">>) -> true;
valid_progress_state(<<"TASK_STATE_INPUT_REQUIRED">>) -> true;
valid_progress_state(<<"TASK_STATE_AUTH_REQUIRED">>) -> true;
valid_progress_state(<<"TASK_STATE_REJECTED">>) -> true;
valid_progress_state(<<"TASK_STATE_FAILED">>) -> true;
valid_progress_state(_) -> false.

finalize_outcome(_Outcome, Entry, State)
  when map_get(terminal_at, Entry) =/= undefined ->
    {Entry, State};
finalize_outcome({completed, {input_required, Message}}, Entry, State) ->
    finalize_status(<<"TASK_STATE_INPUT_REQUIRED">>, Message,
                    false, Entry, State);
finalize_outcome({completed, {auth_required, Message}}, Entry, State) ->
    finalize_status(<<"TASK_STATE_AUTH_REQUIRED">>, Message,
                    false, Entry, State);
finalize_outcome({completed, {rejected, Message}}, Entry, State) ->
    finalize_status(<<"TASK_STATE_REJECTED">>, Message,
                    true, Entry, State);
finalize_outcome({completed, {failed, _Reason}}, Entry, State) ->
    finalize_status(<<"TASK_STATE_FAILED">>,
                    <<"Agent execution failed">>, true, Entry, State);
finalize_outcome({completed, {error, _Reason}}, Entry, State) ->
    finalize_status(<<"TASK_STATE_FAILED">>,
                    <<"Agent execution failed">>, true, Entry, State);
finalize_outcome({completed, {message, Message}}, Entry, State) ->
    DirectMessage = normalize_agent_message(Message, Entry),
    finalize_direct_message(DirectMessage, Entry, State);
finalize_outcome({completed, {ok, Value}}, Entry, State) ->
    finalize_success(Value, Entry, State);
finalize_outcome({completed, Value}, Entry, State) ->
    finalize_success(Value, Entry, State);
finalize_outcome({cancelled, _}, Entry, State) ->
    finalize_status(<<"TASK_STATE_CANCELED">>,
                    <<"Task canceled">>, true, Entry, State);
finalize_outcome({timed_out, _}, Entry, State) ->
    finalize_status(<<"TASK_STATE_FAILED">>,
                    <<"Task deadline exceeded">>, true, Entry, State);
finalize_outcome({failed, _}, Entry, State) ->
    finalize_status(<<"TASK_STATE_FAILED">>,
                    <<"Agent execution failed">>, true, Entry, State).

finalize_success(Value, Entry0, State0) ->
    case output_artifact(Value) of
        {ok, Artifact} ->
            case apply_progress({artifact, Artifact, false, true},
                                Entry0, State0) of
                {ok, Entry1, State1} ->
                    finalize_status(<<"TASK_STATE_COMPLETED">>, undefined,
                                    true, Entry1, State1);
                {error, _} ->
                    finalize_status(
                      <<"TASK_STATE_FAILED">>,
                      <<"Agent response exceeded configured limits">>,
                      true, Entry0, State0)
            end;
        {error, _} ->
            finalize_status(<<"TASK_STATE_FAILED">>,
                            <<"Agent returned an invalid response">>,
                            true, Entry0, State0)
    end.

finalize_direct_message(Message, Entry0, State0) ->
    Task = set_status(maps:get(task, Entry0),
                      <<"TASK_STATE_COMPLETED">>, undefined),
    Entry1 = Entry0#{task => Task,
                     direct_message => Message,
                     terminal_at => erlang:system_time(millisecond)},
    {Entry2, State1} = append_event(
                         #{<<"message">> => Message}, true,
                         Entry1, State0),
    {Entry3, State2} = clear_terminal_push_configs(Entry2, State1),
    close_subscribers(Entry3, State2).

finalize_status(StateName, Message0, Terminal, Entry0, State0) ->
    Message = normalize_agent_message(Message0, Entry0),
    Task1 = set_status(maps:get(task, Entry0), StateName, Message),
    Task = bounded_status_task(Task1, StateName, Entry0, State0),
    case Terminal of
        true -> terminal_status_event(Task, Entry0, State0);
        false -> status_event(Task, Entry0, State0)
    end.

bounded_status_task(Candidate, StateName, Entry, State) ->
    case status_change_allowed(Candidate, State) of
        true -> Candidate;
        false ->
            Fallback = set_status(maps:get(task, Entry), StateName, undefined),
            case status_change_allowed(Fallback, State) of
                true -> Fallback;
                false ->
                    maps:without(
                      [<<"history">>, <<"artifacts">>],
                      Fallback)
            end
    end.

output_artifact(#{<<"artifactId">> := _} = Artifact) ->
    adk_a2a_v1_codec:validate_artifact(Artifact);
output_artifact(Value) when is_binary(Value) ->
    adk_a2a_v1_codec:validate_artifact(
      #{<<"artifactId">> => uuid(<<"artifact-">>),
        <<"parts">> => [#{<<"text">> => Value,
                           <<"mediaType">> => <<"text/plain">>} ]});
output_artifact(Value) ->
    case adk_json:normalize(Value) of
        {ok, Safe} ->
            adk_a2a_v1_codec:validate_artifact(
              #{<<"artifactId">> => uuid(<<"artifact-">>),
                <<"parts">> => [#{<<"data">> => Safe,
                                   <<"mediaType">> =>
                                       <<"application/json">>} ]});
        Error -> Error
    end.

cancel_entry(Entry0, State0) ->
    Task = maps:get(task, Entry0),
    case task_terminal(Task) of
        true -> {reply, {error, task_not_cancelable}, State0};
        false ->
            case maps:get(task_ref, Entry0, undefined) of
                TaskRef when is_binary(TaskRef) ->
                    case adk_task:cancel(TaskRef, a2a_cancelled) of
                        ok ->
                            Refs = maps:remove(TaskRef,
                                              maps:get(task_refs, State0)),
                            Entry1 = Entry0#{task_ref => undefined},
                            {Entry2, State1} = finalize_status(
                                                 <<"TASK_STATE_CANCELED">>,
                                                 <<"Task canceled">>, true,
                                                 Entry1,
                                                 State0#{task_refs => Refs}),
                            {reply, {ok, public_task(maps:get(task, Entry2),
                                                     undefined, true)},
                             put_entry(Entry2, State1)};
                        {error, _} ->
                            {reply, {error, task_not_cancelable}, State0}
                    end;
                undefined ->
                    %% Interrupted tasks (INPUT_REQUIRED/AUTH_REQUIRED) have
                    %% no live worker but remain non-terminal and cancelable.
                    {Entry1, State1} = finalize_status(
                                         <<"TASK_STATE_CANCELED">>,
                                         <<"Task canceled">>, true,
                                         Entry0, State0),
                    {reply, {ok, public_task(maps:get(task, Entry1),
                                             undefined, true)},
                     put_entry(Entry1, State1)};
                _ -> {reply, {error, task_not_cancelable}, State0}
            end
    end.

%% task/event representation

status(StateName, Message) ->
    Base = #{<<"state">> => StateName, <<"timestamp">> => timestamp()},
    case Message of undefined -> Base; _ -> Base#{<<"message">> => Message} end.

set_status(Task, StateName, Message) ->
    Task#{<<"status">> => status(StateName, Message)}.

status_event(Task, Entry0, State0) ->
    Entry1 = Entry0#{task => Task},
    Update = #{<<"taskId">> => maps:get(<<"id">>, Task),
               <<"contextId">> => maps:get(<<"contextId">>, Task),
               <<"status">> => maps:get(<<"status">>, Task)},
    append_event(#{<<"statusUpdate">> => Update}, false, Entry1, State0).

terminal_status_event(Task, Entry0, State0) ->
    Entry1 = Entry0#{task => Task,
                     terminal_at => erlang:system_time(millisecond)},
    Update = #{<<"taskId">> => maps:get(<<"id">>, Task),
               <<"contextId">> => maps:get(<<"contextId">>, Task),
               <<"status">> => maps:get(<<"status">>, Task)},
    {Entry2, State1} = append_event(
                         #{<<"statusUpdate">> => Update}, true,
                         Entry1, State0),
    {Entry3, State2} = clear_terminal_push_configs(Entry2, State1),
    close_subscribers(Entry3, State2).

append_event(Payload, Terminal, Entry0, State0) ->
    {ok, SafePayload} = adk_a2a_v1_codec:validate_stream_response(Payload),
    Config = maps:get(config, State0),
    case event_payload_allowed(SafePayload, Config) of
        false -> {Entry0, State0};
        true ->
            Seq = maps:get(next_seq, Entry0),
            Events0 = maps:get(events, Entry0),
            Max = maps:get(max_events, Config),
            Events1 = trim_events(Events0 ++ [{Seq, SafePayload}], Max),
            {Entry1, State1} = deliver_event(
                                 Entry0, State0, Seq, SafePayload, Terminal),
            State2 = enqueue_push_deliveries(
                       Entry1, State1, Seq, SafePayload),
            {Entry1#{events => Events1,
                     next_seq => Seq + 1,
                     updated_ms => erlang:system_time(millisecond)}, State2}
    end.

enqueue_push_deliveries(Entry, State0, Seq, Payload) ->
    TaskId = maps:get(id, Entry),
    Secrets = maps:get(push_secrets, State0),
    Configs = lists:keysort(
                1, maps:to_list(maps:get(push_configs, Entry, #{}))),
    lists:foldl(
      fun({ConfigId, Public}, StateAcc) ->
          case maps:find({TaskId, ConfigId}, Secrets) of
              {ok, Secret} ->
                  DeliveryId = push_delivery_id(TaskId, ConfigId, Seq),
                  Job = #{key => {TaskId, ConfigId},
                          task_id => TaskId, sequence => Seq,
                          config => Public, secret => Secret,
                          payload => Payload,
                          delivery_id => DeliveryId},
                  enqueue_push_job(Job, StateAcc);
              error -> StateAcc
          end
      end, State0, Configs).

enqueue_push_job(Job, State = #{push_active := Active})
  when map_size(Active) =:= 0 ->
    start_push_worker(Job, State);
enqueue_push_job(Job, State0) ->
    Queue0 = maps:get(push_queue, State0),
    Maximum = maps:get(max_push_queue, maps:get(config, State0)),
    case queue:len(Queue0) < Maximum of
        true -> State0#{push_queue => queue:in(Job, Queue0)};
        false -> State0
    end.

start_push_worker(Job, State0) ->
    Owner = self(),
    DeliveryRef = make_ref(),
    Policy = maps:get(push_policy, maps:get(config, State0)),
    Work = fun() ->
        WorkerPid = self(),
        Guard = spawn(fun() -> push_owner_guard(Owner, WorkerPid) end),
        _ = adk_a2a_v1_push:deliver(Job, Policy),
        Guard ! finished,
        _ = erlang:send(Owner,
                        {a2a_push_delivery_done, self(), DeliveryRef},
                        [nosuspend, noconnect]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?PUSH_WORKER_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Work, SpawnOptions) of
        {Pid, Monitor} ->
            Active = maps:get(push_active, State0),
            Worker = #{pid => Pid, key => maps:get(key, Job),
                       delivery_ref => DeliveryRef},
            State0#{push_active => Active#{Monitor => Worker}}
    catch
        _:_ -> State0
    end.

push_owner_guard(Owner, Worker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        finished ->
            erlang:demonitor(OwnerMonitor, [flush]),
            erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            exit(Worker, kill),
            erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, Worker, _Reason} ->
            erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

take_push_worker(Pid, DeliveryRef, State0) ->
    Active0 = maps:get(push_active, State0),
    case [Ref || {Ref, #{pid := WorkerPid,
                         delivery_ref := RefValue}} <- maps:to_list(Active0),
                 WorkerPid =:= Pid, RefValue =:= DeliveryRef] of
        [Monitor] ->
            _ = erlang:demonitor(Monitor, [flush]),
            {ok, State0#{push_active => maps:remove(Monitor, Active0)}};
        [] -> error
    end.

start_queued_push(State = #{push_active := Active})
  when map_size(Active) > 0 -> State;
start_queued_push(State0) ->
    case queue:out(maps:get(push_queue, State0)) of
        {{value, Job}, Queue} ->
            start_push_worker(Job, State0#{push_queue => Queue});
        {empty, _} -> State0
    end.

cancel_push_key(Key, State0) ->
    Active0 = maps:get(push_active, State0),
    Active = maps:fold(
      fun(Monitor, #{pid := Pid, key := WorkerKey} = Worker, Acc) ->
          case WorkerKey =:= Key of
              true ->
                  _ = erlang:demonitor(Monitor, [flush]),
                  exit(Pid, kill),
                  Acc;
              false -> Acc#{Monitor => Worker}
          end
      end, #{}, Active0),
    Pending = [Job || Job <- queue:to_list(maps:get(push_queue, State0)),
                       maps:get(key, Job) =/= Key],
    start_queued_push(State0#{push_active => Active,
                              push_queue => queue:from_list(Pending)}).

clear_terminal_push_configs(Entry0, State0) ->
    TaskId = maps:get(id, Entry0),
    ConfigIds = maps:keys(maps:get(push_configs, Entry0, #{})),
    Secrets0 = maps:get(push_secrets, State0),
    Secrets = lists:foldl(
                fun(ConfigId, Acc) ->
                    maps:remove({TaskId, ConfigId}, Acc)
                end, Secrets0, ConfigIds),
    {Entry0#{push_configs => #{}}, State0#{push_secrets => Secrets}}.

push_delivery_id(TaskId, ConfigId, Seq) ->
    Digest = crypto:hash(
               sha256,
               term_to_binary({TaskId, ConfigId, Seq}, [deterministic])),
    base64url(Digest).

%% A slow Cowboy/request process must not turn the task store into an
%% unbounded mailbox producer. Once the configured queue ceiling is reached,
%% detach that subscriber and enqueue one terminal control message behind the
%% already accepted events. The HTTP handler closes the connection; the client
%% can reconnect with Last-Event-ID while the retained replay window exists.
deliver_event(Entry0, State0, Seq, Payload, Terminal) ->
    Config = maps:get(config, State0),
    Maximum = maps:get(max_subscriber_queue, Config),
    TaskId = maps:get(id, Entry0),
    Refs0 = maps:get(subscriber_refs, State0),
    {Subscribers, Refs} = maps:fold(
      fun(Ref, Pid, {SubscribersAcc, RefsAcc}) ->
          Message = {adk_a2a_v1_event, TaskId, Seq, Payload, Terminal},
          case subscriber_ready(Pid, Maximum) andalso
               safe_subscriber_send(Pid, Message) of
              true ->
                  {SubscribersAcc#{Ref => Pid}, RefsAcc};
              false ->
                  _ = erlang:demonitor(Ref, [flush]),
                  _ = safe_subscriber_send(
                        Pid, {adk_a2a_v1_overflow, TaskId}),
                  {SubscribersAcc, maps:remove(Ref, RefsAcc)}
          end
      end, {#{}, Refs0}, maps:get(subscribers, Entry0)),
    {Entry0#{subscribers => Subscribers},
     State0#{subscriber_refs => Refs}}.

subscriber_ready(Pid, Maximum) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Length} when Length < Maximum -> true;
        _ -> false
    end.

safe_subscriber_send(Pid, Message) ->
    try erlang:send(Pid, Message, [nosuspend, noconnect]) of
        ok -> true;
        _ -> false
    catch
        error:badarg -> false
    end.

trim_events(Events, Max) ->
    Extra = length(Events) - Max,
    case Extra > 0 of true -> lists:nthtail(Extra, Events); false -> Events end.

replay_frames(Entry, Cursor) ->
    Snapshot = {Cursor,
                #{<<"task">> => public_task(maps:get(task, Entry),
                                             undefined, true)}},
    Replayed = [{Seq, Payload}
                || {Seq, Payload} <- maps:get(events, Entry),
                   Seq > Cursor,
                   not maps:is_key(<<"task">>, Payload)],
    [Snapshot | Replayed].

replay_available(Entry, Cursor) ->
    case maps:get(events, Entry) of
        [] -> true;
        [{Oldest, _} | _] -> Cursor >= Oldest - 1
    end.

public_task(Task0, HistoryLength, IncludeArtifacts) ->
    Task1 = case HistoryLength of
        undefined -> Task0;
        0 -> maps:remove(<<"history">>, Task0);
        N when is_integer(N), N > 0 ->
            History = maps:get(<<"history">>, Task0, []),
            Task0#{<<"history">> => take_last(History, N)}
    end,
    case IncludeArtifacts of
        true -> Task1;
        false -> maps:remove(<<"artifacts">>, Task1)
    end.

take_last(List, N) ->
    Length = length(List),
    case Length =< N of true -> List; false -> lists:nthtail(Length - N, List) end.

task_state(Task) ->
    maps:get(<<"state">>, maps:get(<<"status">>, Task)).

task_terminal(Task) -> adk_a2a_v1_codec:terminal_state(task_state(Task)).

agent_message(Entry, Text) ->
    Task = maps:get(task, Entry),
    #{<<"messageId">> => uuid(<<"message-">>),
      <<"contextId">> => maps:get(<<"contextId">>, Task),
      <<"taskId">> => maps:get(<<"id">>, Task),
      <<"role">> => <<"ROLE_AGENT">>,
      <<"parts">> => [#{<<"text">> => Text,
                         <<"mediaType">> => <<"text/plain">>}]}.

normalize_agent_message(undefined, _Entry) -> undefined;
normalize_agent_message(Text, Entry) when is_binary(Text) ->
    agent_message(Entry, Text);
normalize_agent_message(Message0, Entry) when is_map(Message0) ->
    Task = maps:get(task, Entry),
    Message1 = Message0#{<<"messageId">> => maps:get(
                           <<"messageId">>, Message0,
                           uuid(<<"message-">>)),
                         <<"contextId">> => maps:get(<<"contextId">>, Task),
                         <<"taskId">> => maps:get(<<"id">>, Task),
                         <<"role">> => <<"ROLE_AGENT">>},
    case adk_a2a_v1_codec:validate_message(Message1) of
        {ok, Message} -> Message;
        {error, _} -> agent_message(Entry, <<"Agent status changed">>)
    end;
normalize_agent_message(_, Entry) ->
    agent_message(Entry, <<"Agent status changed">>).

merge_artifact(Task, Artifact, false) ->
    Id = maps:get(<<"artifactId">>, Artifact),
    Existing = maps:get(<<"artifacts">>, Task, []),
    Filtered = [A || A <- Existing,
                     maps:get(<<"artifactId">>, A) =/= Id],
    Task#{<<"artifacts">> => Filtered ++ [Artifact]};
merge_artifact(Task, Artifact, true) ->
    Id = maps:get(<<"artifactId">>, Artifact),
    Existing = maps:get(<<"artifacts">>, Task, []),
    Updated = case lists:keytake(Id, 1,
                                 [{maps:get(<<"artifactId">>, A), A}
                                  || A <- Existing]) of
        {value, {_Id, Previous}, RestPairs} ->
            Parts = maps:get(<<"parts">>, Previous) ++
                    maps:get(<<"parts">>, Artifact),
            [A || {_Key, A} <- RestPairs] ++
                [(maps:merge(Previous, Artifact))#{<<"parts">> => Parts}];
        false -> Existing ++ [Artifact]
    end,
    Task#{<<"artifacts">> => Updated}.

%% subscriptions

maybe_subscribe(undefined, Entry, State) -> {ok, Entry, State};
maybe_subscribe(Pid, Entry, State) -> add_subscriber(Pid, Entry, State).

add_subscriber(Pid, Entry0, State0) ->
    Subs = maps:get(subscribers, Entry0),
    Max = maps:get(max_subscribers_per_task, maps:get(config, State0)),
    case lists:any(fun({_Ref, Existing}) -> Existing =:= Pid end,
                   maps:to_list(Subs)) of
        true -> {ok, Entry0, State0};
        false when map_size(Subs) >= Max -> {error, subscriber_capacity};
        false ->
            Ref = erlang:monitor(process, Pid),
            TaskId = maps:get(id, Entry0),
            Refs = maps:get(subscriber_refs, State0),
            {ok, Entry0#{subscribers => Subs#{Ref => Pid}},
             State0#{subscriber_refs => Refs#{Ref => {TaskId, Pid}}}}
    end.

remove_subscriber(TaskId, Subscriber, State0) ->
    case maps:find(TaskId, maps:get(tasks, State0)) of
        error -> {State0, false};
        {ok, Entry0} ->
            Matches = [{Ref, Pid} || {Ref, Pid} <-
                                       maps:to_list(maps:get(subscribers,
                                                            Entry0)),
                                      Pid =:= Subscriber],
            lists:foldl(
              fun({Ref, Pid}, {StateAcc, _}) ->
                  remove_subscriber_ref(TaskId, Pid, Ref, StateAcc)
              end, {State0, false}, Matches)
    end.

remove_subscriber_ref(TaskId, _Subscriber, Ref, State0) ->
    _ = erlang:demonitor(Ref, [flush]),
    Refs = maps:remove(Ref, maps:get(subscriber_refs, State0)),
    case maps:find(TaskId, maps:get(tasks, State0)) of
        {ok, Entry0} ->
            Subs = maps:remove(Ref, maps:get(subscribers, Entry0)),
            Entry1 = Entry0#{subscribers => Subs},
            {put_entry(Entry1, State0#{subscriber_refs => Refs}), true};
        error -> {State0#{subscriber_refs => Refs}, false}
    end.

close_subscribers(Entry0, State0) ->
    {State1, _} = lists:foldl(
      fun({Ref, Pid}, {StateAcc, _}) ->
          remove_subscriber_ref(maps:get(id, Entry0), Pid, Ref, StateAcc)
      end, {put_entry(Entry0, State0), false},
      maps:to_list(maps:get(subscribers, Entry0))),
    case maps:find(maps:get(id, Entry0), maps:get(tasks, State1)) of
        {ok, Entry1} -> {Entry1, State1};
        error -> {Entry0#{subscribers => #{}}, State1}
    end.

%% lookup/list/pagination

visible_entry(TaskId, Scope, State) when is_binary(TaskId), is_binary(Scope) ->
    case maps:find(TaskId, maps:get(tasks, State)) of
        {ok, #{scope := Scope} = Entry} -> {ok, Entry};
        _ -> error
    end;
visible_entry(_, _, _) -> error.

validate_get_params(Params) ->
    case {required_id(Params),
          maps:get(<<"historyLength">>, Params, undefined)} of
        {{ok, Id}, History} ->
            case valid_optional_nonneg(History) of
                true -> {ok, Id, History};
                false -> {error, invalid_history_length}
            end;
        {{error, _} = Error, _} -> Error
    end.

required_id(Params) when is_map(Params) ->
    case maps:get(<<"id">>, Params, undefined) of
        Id when is_binary(Id), byte_size(Id) > 0 -> {ok, Id};
        _ -> {error, invalid_task_id}
    end;
required_id(_) -> {error, invalid_params}.

subscribe_input(Params) ->
    case required_id(Params) of
        {ok, Id} ->
            Cursor = maps:get(last_event_id, Params, 0),
            case is_integer(Cursor) andalso Cursor >= 0 of
                true -> {ok, Id, Cursor};
                false -> {error, invalid_last_event_id}
            end;
        Error -> Error
    end.

list_visible(Scope, Params, State) when is_map(Params) ->
    case list_options(Params) of
        {ok, Options} ->
            Entries0 = [Entry || {_Id, Entry = #{scope := EntryScope}} <-
                                      maps:to_list(maps:get(tasks, State)),
                                  EntryScope =:= Scope],
            Entries1 = lists:filter(fun(E) -> list_match(E, Options) end,
                                    Entries0),
            Sorted = lists:sort(fun newer_entry/2, Entries1),
            Total = length(Sorted),
            case after_cursor(Sorted, maps:get(page_token, Options), State) of
                {ok, Remaining} ->
                    PageSize = maps:get(page_size, Options),
                    {Page, Tail} = split_at(Remaining, PageSize),
                    Next = case Tail of
                        [] -> <<>>;
                        _ -> encode_cursor(lists:last(Page), State)
                    end,
                    Tasks = [public_task(maps:get(task, E),
                                         maps:get(history_length, Options),
                                         maps:get(include_artifacts, Options))
                             || E <- Page],
                    {ok, #{<<"tasks">> => Tasks,
                           <<"nextPageToken">> => Next,
                           <<"pageSize">> => PageSize,
                           <<"totalSize">> => Total}};
                {error, _} = Error -> Error
            end;
        Error -> Error
    end;
list_visible(_Scope, _Params, _State) -> {error, invalid_params}.

list_options(Params) ->
    PageSize = maps:get(<<"pageSize">>, Params, 50),
    History = maps:get(<<"historyLength">>, Params, undefined),
    Include = maps:get(<<"includeArtifacts">>, Params, false),
    Status = maps:get(<<"status">>, Params, undefined),
    Context = maps:get(<<"contextId">>, Params, undefined),
    After = maps:get(<<"statusTimestampAfter">>, Params, undefined),
    Token = maps:get(<<"pageToken">>, Params, <<>>),
    case PageSize >= 1 andalso PageSize =< 100
         andalso valid_optional_nonneg(History)
         andalso is_boolean(Include)
         andalso valid_optional_binary(Status)
         andalso valid_optional_binary(Context)
         andalso valid_timestamp_filter(After)
         andalso is_binary(Token) of
        true -> {ok, #{page_size => PageSize,
                       history_length => History,
                       include_artifacts => Include,
                       status => Status, context_id => Context,
                       timestamp_after => After, page_token => Token}};
        false -> {error, invalid_list_tasks_params}
    end.

list_match(Entry, Options) ->
    Task = maps:get(task, Entry),
    optional_equal(maps:get(status, Options), task_state(Task))
    andalso optional_equal(maps:get(context_id, Options),
                           maps:get(<<"contextId">>, Task))
    andalso timestamp_match(maps:get(timestamp_after, Options), Task).

optional_equal(undefined, _Actual) -> true;
optional_equal(Expected, Actual) -> Expected =:= Actual.

timestamp_match(undefined, _Task) -> true;
timestamp_match(After, Task) ->
    Timestamp = maps:get(<<"timestamp">>, maps:get(<<"status">>, Task)),
    Timestamp >= After.

newer_entry(A, B) ->
    {maps:get(updated_ms, A), maps:get(id, A)} >
    {maps:get(updated_ms, B), maps:get(id, B)}.

after_cursor(Entries, <<>>, _State) -> {ok, Entries};
after_cursor(Entries, Token, State) ->
    case decode_cursor(Token, State) of
        {ok, Pair} -> drop_through(Entries, Pair);
        error -> {error, invalid_page_token}
    end.

drop_through([], _Pair) -> {error, invalid_page_token};
drop_through([Entry | Rest], Pair) ->
    case {maps:get(updated_ms, Entry), maps:get(id, Entry)} of
        Pair -> {ok, Rest};
        _ -> drop_through(Rest, Pair)
    end.

encode_cursor(Entry, State) ->
    Payload = term_to_binary({maps:get(updated_ms, Entry), maps:get(id, Entry)},
                             [deterministic]),
    Mac = crypto:mac(hmac, sha256, maps:get(cursor_secret, State), Payload),
    base64url(<<Mac/binary, Payload/binary>>).

decode_cursor(Token, State) ->
    try base64url_decode(Token) of
        <<Mac:32/binary, Payload/binary>> ->
            Expected = crypto:mac(hmac, sha256,
                                  maps:get(cursor_secret, State), Payload),
            case adk_dev_auth:constant_time_equal(Mac, Expected) of
                true ->
                    case binary_to_term(Payload, [safe]) of
                        {Ms, Id} when is_integer(Ms), is_binary(Id) ->
                            {ok, {Ms, Id}};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    catch _:_ -> error
    end.

split_at(List, N) ->
    split_at(List, N, []).
split_at(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
split_at([], _N, Acc) -> {lists:reverse(Acc), []};
split_at([Head | Rest], N, Acc) ->
    split_at(Rest, N - 1, [Head | Acc]).

%% state/capacity helpers

put_entry(Entry, State) ->
    ok = persist_task_entry(Entry, maps:get(config, State)),
    Tasks = maps:get(tasks, State),
    State#{tasks => Tasks#{maps:get(id, Entry) => Entry}}.

active_count(State) ->
    length([ok || {_Id, Entry} <- maps:to_list(maps:get(tasks, State)),
                  maps:get(terminal_at, Entry) =:= undefined,
                  maps:get(task_ref, Entry, undefined) =/= undefined]).

ensure_task_capacity(State) ->
    Max = maps:get(max_tasks, maps:get(config, State)),
    case map_size(maps:get(tasks, State)) < Max of
        true -> {ok, State};
        false ->
            case oldest_terminal(State) of
                undefined -> {error, capacity, State};
                TaskId -> {ok, remove_task(TaskId, State)}
            end
    end.

oldest_terminal(State) ->
    Terminal = [{maps:get(terminal_at, Entry), TaskId}
                || {TaskId, Entry} <- maps:to_list(maps:get(tasks, State)),
                   maps:get(terminal_at, Entry) =/= undefined],
    case lists:sort(Terminal) of [] -> undefined; [{_, Id} | _] -> Id end.

prune(State) ->
    Retention = maps:get(retention_ms, maps:get(config, State)),
    Cutoff = erlang:system_time(millisecond) - Retention,
    Expired = [TaskId || {TaskId, Entry} <-
                             maps:to_list(maps:get(tasks, State)),
                         is_integer(maps:get(terminal_at, Entry)),
                         maps:get(terminal_at, Entry) =< Cutoff],
    lists:foldl(fun remove_task/2, State, Expired).

remove_task(TaskId, State0) ->
    case maps:take(TaskId, maps:get(tasks, State0)) of
        {Entry, Tasks} ->
            ok = delete_task_snapshot(TaskId, maps:get(config, State0)),
            State1 = State0#{tasks => Tasks},
            lists:foldl(
              fun({Ref, Pid}, Acc) ->
                  element(1, remove_subscriber_ref(TaskId, Pid, Ref, Acc))
              end, State1, maps:to_list(maps:get(subscribers, Entry)));
        error -> State0
    end.

%% task-store persistence

restore_task_snapshots(#{task_store := undefined}) -> {ok, #{}};
restore_task_snapshots(Config = #{task_store := {Module, Handle}}) ->
    case safe_task_store_call(Module, load, [Handle]) of
        {ok, Snapshots} when is_list(Snapshots),
                             length(Snapshots) =< map_get(max_tasks, Config) ->
            restore_snapshot_list(Snapshots, Config, #{});
        {ok, _} -> {error, a2a_task_store_capacity_reached};
        {error, Reason} -> {error, {a2a_task_store_load_failed, Reason}};
        _ -> {error, a2a_task_store_invalid_load_result}
    end.

restore_snapshot_list([], _Config, Acc) -> {ok, Acc};
restore_snapshot_list([Snapshot0 | Rest], Config, Acc) ->
    case adk_a2a_v1_task_store:prepare_snapshot(Snapshot0) of
        {ok, Snapshot, _Bytes} ->
            Entry0 = Snapshot#{task_ref => undefined, subscribers => #{},
                              direct_message => undefined},
            Entry = recover_snapshot_entry(Entry0, Config),
            Id = maps:get(id, Entry),
            case maps:is_key(Id, Acc) orelse
                 not retained_task_allowed(maps:get(task, Entry), Config) of
                true -> {error, invalid_a2a_task_store_snapshot};
                false ->
                    ok = persist_task_entry(Entry, Config),
                    restore_snapshot_list(Rest, Config, Acc#{Id => Entry})
            end;
        {error, Reason} -> {error, {invalid_a2a_task_store_snapshot, Reason}}
    end.

recover_snapshot_entry(Entry0, Config) ->
    Task0 = maps:get(task, Entry0),
    case task_state(Task0) of
        <<"TASK_STATE_SUBMITTED">> -> recover_incomplete_entry(Entry0, Config);
        <<"TASK_STATE_WORKING">> -> recover_incomplete_entry(Entry0, Config);
        _ -> Entry0
    end.

recover_incomplete_entry(Entry0, Config) ->
    Task = set_status(maps:get(task, Entry0), <<"TASK_STATE_FAILED">>,
                      undefined),
    Seq = maps:get(next_seq, Entry0),
    Payload = #{<<"statusUpdate">> =>
                    #{<<"taskId">> => maps:get(id, Entry0),
                      <<"contextId">> => maps:get(<<"contextId">>, Task),
                      <<"status">> => maps:get(<<"status">>, Task)}},
    Events = trim_events(maps:get(events, Entry0) ++ [{Seq, Payload}],
                         maps:get(max_events, Config)),
    Now = erlang:system_time(millisecond),
    Entry0#{task => Task, events => Events, next_seq => Seq + 1,
            updated_ms => Now, terminal_at => Now}.

persist_task_entry(_Entry, #{task_store := undefined}) -> ok;
persist_task_entry(Entry, #{task_store := {Module, Handle}}) ->
    Snapshot = maps:with([id, scope, task, events, next_seq,
                          updated_ms, terminal_at], Entry),
    case safe_task_store_call(Module, put, [Handle, Snapshot]) of
        ok -> ok;
        {error, Reason} -> exit({a2a_task_store_write_failed, Reason});
        _ -> exit(a2a_task_store_invalid_write_result)
    end.

delete_task_snapshot(_TaskId, #{task_store := undefined}) -> ok;
delete_task_snapshot(TaskId, #{task_store := {Module, Handle}}) ->
    case safe_task_store_call(Module, delete, [Handle, TaskId]) of
        ok -> ok;
        {error, Reason} -> exit({a2a_task_store_delete_failed, Reason});
        _ -> exit(a2a_task_store_invalid_delete_result)
    end.

safe_task_store_call(Module, Function, Args) ->
    try apply(Module, Function, Args) of
        Reply -> Reply
    catch
        _:_ -> {error, task_store_unavailable}
    end.

%% scalar helpers

send_history_length(Params) ->
    maps:get(<<"historyLength">>,
             maps:get(<<"configuration">>, Params, #{}), undefined).

valid_optional_nonneg(undefined) -> true;
valid_optional_nonneg(Value) -> is_integer(Value) andalso Value >= 0.

valid_optional_binary(undefined) -> true;
valid_optional_binary(Value) -> is_binary(Value) andalso byte_size(Value) > 0.

valid_timestamp_filter(undefined) -> true;
valid_timestamp_filter(Value) when is_binary(Value) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Value),
                                        [{unit, millisecond}]) of
        _ -> true
    catch _:_ -> false
    end;
valid_timestamp_filter(_) -> false.

timestamp() ->
    unicode:characters_to_binary(
      calendar:system_time_to_rfc3339(
        erlang:system_time(millisecond),
        [{unit, millisecond}, {offset, "Z"}])).

uuid(Prefix) ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    Id = list_to_binary(
           io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                         [A, B, C band 16#0fff,
                          D band 16#3fff bor 16#8000, E])),
    <<Prefix/binary, Id/binary>>.

base64url(Binary) ->
    NoPadding = binary:replace(base64:encode(Binary), <<"=">>, <<>>,
                               [global]),
    binary:replace(binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

base64url_decode(Binary) ->
    Standard = binary:replace(binary:replace(Binary, <<"-">>, <<"+">>,
                                             [global]),
                              <<"_">>, <<"/">>, [global]),
    Padding = case byte_size(Standard) rem 4 of
        0 -> <<>>; 2 -> <<"==">>; 3 -> <<"=">>; _ -> erlang:error(badarg)
    end,
    base64:decode(<<Standard/binary, Padding/binary>>).
