%% @doc Declarative, bounded workflow API.
%%
%% A compiled workflow is immutable. Each started workflow has a detached
%% coordinator which owns its checkpoint and terminal outcome; potentially
%% blocking actions execute in monitored workers. Public checkpoints contain
%% JSON-safe values only and can be used to resume from the last committed
%% boundary with the remaining non-time budgets intact.
-module(adk_workflow).

-export([compile/1,
         start/2, start/3,
         start_invocation/3,
         run/2, run/3,
         await/1, await/2,
         cancel/1, cancel/2,
         status/1,
         checkpoint/1,
         resume/2, resume/3,
         resume_invocation/3,
         invocation_status/2,
         delete_invocation/2]).

%% Internal contracts used by the coordinator and engine. They are exported so
%% the runtime can stay split into small modules, but are not user-facing API.
-export([is_compiled/1, initial_checkpoint/3, validate_checkpoint/2,
         prepare_resume_checkpoint/3, sanitize_reason/1,
         external_reason/3, exception_reason/4, failure_reason/1,
         terminal_outcome/3, public_invocation_record/1]).

-define(COMPILED_MARKER, '$adk_workflow_compiled').
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_MAX_STEPS, 1000).
-define(DEFAULT_MAX_TRANSFERS, 16).
-define(DEFAULT_RETENTION_MS, 60000).
-define(CALL_TIMEOUT, 5000).
-define(DEFAULT_LEASE_MS, 30000).
-define(DURABLE_OPT, '$adk_durable_invocation').

-type workflow_ref() :: pid().
-type checkpoint() :: map().
-type outcome() ::
    {completed, map(), checkpoint()}
    | {paused, map(), checkpoint()}
    | {failed, term(), checkpoint()}
    | {timed_out, checkpoint()}
    | {cancelled, term(), checkpoint()}.
-export_type([workflow_ref/0, checkpoint/0, outcome/0]).

%% @doc Validate and compile a declarative workflow specification.
-spec compile(map()) -> {ok, map()} | {error, term()}.
compile(Spec) when is_map(Spec) ->
    try
        Version = get_field(version, Spec, 1),
        Id = get_field(id, Spec, undefined),
        Kind0 = get_field(kind, Spec, undefined),
        case validate_header(Version, Id, Kind0) of
            {ok, Kind} ->
                case compile_kind(Kind, Spec) of
                    {ok, Data} ->
                        case compile_workflow_schemas(Spec) of
                            {ok, InputSchema, OutputSchema} ->
                                {ok, #{?COMPILED_MARKER => true,
                                       version => Version,
                                       id => Id,
                                       kind => Kind,
                                       data => Data,
                                       input_schema => InputSchema,
                                       output_schema => OutputSchema}};
                            {error, _} = Error -> Error
                        end;
                    {error, _} = Error -> Error
                end;
            {error, _} = Error -> Error
        end
    catch
        error:{invalid_workflow, Path, Reason} ->
            invalid(Path, Reason)
    end;
compile(_Other) ->
    invalid([], expected_map).

-spec start(map(), map()) -> {ok, workflow_ref()} | {error, term()}.
start(Compiled, InitialState) ->
    start(Compiled, InitialState, #{}).

-spec start(map(), map(), map()) ->
    {ok, workflow_ref()} | {error, term()}.
start(Compiled, InitialState, Opts)
  when is_map(InitialState), is_map(Opts) ->
    case is_compiled(Compiled) of
        true -> start_supervised(Compiled, InitialState, Opts);
        false -> {error, invalid_compiled_workflow}
    end;
start(_Compiled, _InitialState, _Opts) ->
    {error, invalid_start_arguments}.

%% @doc Start a checkpointed workflow with a stable durable invocation ID.
%%
%% Opts must contain `ledger => {Module, Handle}', where Module implements
%% adk_invocation_ledger.  The returned ID, unlike the coordinator pid, stays
%% valid across coordinator and VM/application restarts.  An optional binary
%% `invocation_id' may be supplied for upstream idempotent creation.
-spec start_invocation(map(), map(), map()) ->
    {ok, binary(), workflow_ref()} | {error, term()}.
start_invocation(Compiled, InitialState, Opts)
  when is_map(InitialState), is_map(Opts) ->
    case {is_compiled(Compiled), durable_options(Opts)} of
        {false, _} -> {error, invalid_compiled_workflow};
        {true, {error, _} = Error} -> Error;
        {true, {ok, Ledger, LeaseMs}} ->
            InvocationId = maps:get(invocation_id, Opts,
                                    generate_invocation_id()),
            case valid_id(InvocationId) of
                false ->
                    {error, {invalid_invocation_id,
                             external_reason(adk_workflow,
                                             invocation_id,
                                             InvocationId)}};
                true ->
                    Durable = #{mode => create,
                                invocation_id => InvocationId,
                                ledger => Ledger,
                                lease_ms => LeaseMs},
                    case start_supervised(
                           Compiled, InitialState,
                           Opts#{?DURABLE_OPT => Durable}) of
                        {ok, Ref} -> {ok, InvocationId, Ref};
                        {error, _} = Error -> Error
                    end
            end
    end;
start_invocation(_Compiled, _InitialState, _Opts) ->
    {error, invalid_start_invocation_arguments}.

-spec run(map(), map()) -> outcome() | {error, term()}.
run(Compiled, InitialState) ->
    run(Compiled, InitialState, #{}).

-spec run(map(), map(), map()) -> outcome() | {error, term()}.
run(Compiled, InitialState, Opts) ->
    case start(Compiled, InitialState, Opts) of
        {ok, Ref} -> await(Ref, infinity);
        {error, _} = Error -> Error
    end.

-spec await(workflow_ref()) -> outcome() | {error, term()}.
await(Ref) ->
    await(Ref, infinity).

-spec await(workflow_ref(), timeout()) -> outcome() | {error, term()}.
await(Ref, Timeout)
  when is_pid(Ref),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    safe_call(Ref, await, Timeout);
await(_Ref, _Timeout) ->
    {error, invalid_await_arguments}.

-spec cancel(workflow_ref()) -> ok | {error, term()}.
cancel(Ref) ->
    cancel(Ref, user_cancelled).

-spec cancel(workflow_ref(), term()) -> ok | {error, term()}.
cancel(Ref, Reason) when is_pid(Ref) ->
    safe_call(Ref, {cancel, Reason}, ?CALL_TIMEOUT);
cancel(_Ref, _Reason) ->
    {error, invalid_workflow_ref}.

-spec status(workflow_ref()) -> {ok, map()} | {error, term()}.
status(Ref) when is_pid(Ref) ->
    case safe_call(Ref, status, ?CALL_TIMEOUT) of
        Reply when is_map(Reply) -> {ok, Reply};
        {error, _} = Error -> Error
    end;
status(_Ref) ->
    {error, invalid_workflow_ref}.

-spec checkpoint(workflow_ref()) -> {ok, checkpoint()} | {error, term()}.
checkpoint(Ref) when is_pid(Ref) ->
    case safe_call(Ref, checkpoint, ?CALL_TIMEOUT) of
        Reply when is_map(Reply) -> {ok, Reply};
        {error, _} = Error -> Error
    end;
checkpoint(_Ref) ->
    {error, invalid_workflow_ref}.

-spec resume(map(), checkpoint()) ->
    {ok, workflow_ref()} | {error, term()}.
resume(Compiled, Checkpoint) ->
    resume(Compiled, Checkpoint, #{}).

-spec resume(map(), checkpoint(), map()) ->
    {ok, workflow_ref()} | {error, term()}.
resume(Compiled, Checkpoint, Opts) when is_map(Opts) ->
    case validate_checkpoint(Compiled, Checkpoint) of
        {ok, State} ->
            case prepare_resume_checkpoint(Compiled, Checkpoint, Opts) of
                {ok, ResumeCheckpoint} ->
                    start(Compiled, State,
                          Opts#{resume_checkpoint => ResumeCheckpoint});
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
resume(_Compiled, _Checkpoint, _Opts) ->
    {error, invalid_resume_arguments}.

%% @doc Claim and resume a durable workflow by stable invocation ID.
%%
%% Exactly one live coordinator can own an invocation.  A dead local owner is
%% replaced immediately; a remote owner can be replaced only after its lease
%% expires. Completed invocations are immutable and cannot be resumed.
-spec resume_invocation(binary(), map(), map()) ->
    {ok, workflow_ref()} | {error, term()}.
resume_invocation(InvocationId, Compiled, Opts)
  when is_binary(InvocationId), is_map(Opts) ->
    case {is_compiled(Compiled), durable_options(Opts)} of
        {false, _} -> {error, invalid_compiled_workflow};
        {true, {error, _} = Error} -> Error;
        {true, {ok, {Module, Handle} = Ledger, LeaseMs}} ->
            case safe_ledger_call(Module, get, [Handle, InvocationId]) of
                {ok, Record} ->
                    resume_durable_record(InvocationId, Compiled, Opts,
                                          Ledger, LeaseMs, Record);
                {error, Reason} ->
                    {error, external_reason(adk_workflow_ledger, get,
                                            Reason)};
                Other -> {error, {invalid_ledger_reply, get,
                                  external_reason(adk_workflow_ledger, get,
                                                  Other)}}
            end
    end;
resume_invocation(InvocationId, _Compiled, _Opts) ->
    {error, {invalid_invocation_id,
             external_reason(adk_workflow, invocation_id, InvocationId)}}.

%% @doc Read persisted invocation state without requiring a live coordinator.
-spec invocation_status(binary(), map()) -> {ok, map()} | {error, term()}.
invocation_status(InvocationId, Opts)
  when is_binary(InvocationId), is_map(Opts) ->
    case durable_options(Opts) of
        {ok, {Module, Handle}, _LeaseMs} ->
            case safe_ledger_call(Module, get, [Handle, InvocationId]) of
                {ok, Record} when is_map(Record) ->
                    {ok, public_invocation_record(Record)};
                {error, Reason} ->
                    {error, external_reason(adk_workflow_ledger, get,
                                            Reason)};
                Other -> {error, {invalid_ledger_reply, get,
                                  external_reason(adk_workflow_ledger, get,
                                                  Other)}}
            end;
        {error, _} = Error -> Error
    end;
invocation_status(InvocationId, _Opts) ->
    {error, {invalid_invocation_id,
             external_reason(adk_workflow, invocation_id, InvocationId)}}.

%% @doc Delete an unowned durable invocation from its ledger.
-spec delete_invocation(binary(), map()) -> ok | {error, term()}.
delete_invocation(InvocationId, Opts)
  when is_binary(InvocationId), is_map(Opts) ->
    case durable_options(Opts) of
        {ok, {Module, Handle}, _LeaseMs} ->
            case safe_ledger_call(Module, delete, [Handle, InvocationId]) of
                ok -> ok;
                {error, Reason} ->
                    {error, external_reason(adk_workflow_ledger, delete,
                                            Reason)};
                Other -> {error, {invalid_ledger_reply, delete,
                                  external_reason(adk_workflow_ledger, delete,
                                                  Other)}}
            end;
        {error, _} = Error -> Error
    end;
delete_invocation(InvocationId, _Opts) ->
    {error, {invalid_invocation_id,
             external_reason(adk_workflow, invocation_id, InvocationId)}}.

%% Internal validation and checkpoint helpers

is_compiled(#{?COMPILED_MARKER := true,
              version := 1,
              id := Id,
              kind := Kind,
              data := Data}) ->
    is_binary(Id) andalso
    lists:member(Kind, [sequential, parallel, loop, transfer, graph])
    andalso is_map(Data);
is_compiled(_) ->
    false.

initial_checkpoint(Compiled, State, Runtime) ->
    Kind = maps:get(kind, Compiled),
    Cursor = initial_cursor(Kind, maps:get(data, Compiled)),
    checkpoint_map(Compiled, State, Cursor,
                   maps:get(steps_remaining, Runtime),
                   maps:get(transfers_remaining, Runtime), false).

validate_checkpoint(Compiled, Checkpoint)
  when is_map(Checkpoint) ->
    case is_compiled(Compiled) of
        false -> {error, invalid_compiled_workflow};
        true ->
            Id = maps:get(id, Compiled),
            KindBin = kind_binary(maps:get(kind, Compiled)),
            Expected = {1, Id, maps:get(version, Compiled), KindBin},
            Actual = {
                maps:get(<<"schema_version">>, Checkpoint, undefined),
                maps:get(<<"workflow_id">>, Checkpoint, undefined),
                maps:get(<<"workflow_version">>, Checkpoint, undefined),
                maps:get(<<"kind">>, Checkpoint, undefined)
            },
            case Actual =:= Expected of
                false -> {error, checkpoint_workflow_mismatch};
                true -> validate_checkpoint_body(Compiled, Checkpoint)
            end
    end;
validate_checkpoint(_Compiled, _Checkpoint) ->
    {error, invalid_checkpoint}.

validate_checkpoint_body(Compiled, Checkpoint) ->
    Completed = maps:get(<<"completed">>, Checkpoint, undefined),
    State = maps:get(<<"state">>, Checkpoint, undefined),
    Cursor = maps:get(<<"cursor">>, Checkpoint, undefined),
    Remaining = maps:get(<<"remaining">>, Checkpoint, undefined),
    case Completed of
        true -> {error, checkpoint_complete};
        false when is_map(State), is_map(Cursor), is_map(Remaining) ->
            Steps = maps:get(<<"steps">>, Remaining, undefined),
            Transfers = maps:get(<<"transfers">>, Remaining, undefined),
            case valid_non_neg(Steps) andalso valid_non_neg(Transfers)
                 andalso valid_checkpoint_output(Checkpoint)
                 andalso valid_cursor(maps:get(kind, Compiled),
                                      maps:get(data, Compiled), Cursor) of
                true ->
                    case adk_json:normalize(State) of
                        {ok, State} -> {ok, State};
                        {ok, _Changed} -> {error, invalid_checkpoint_state};
                        {error, _} -> {error, invalid_checkpoint_state}
                    end;
                false -> {error, invalid_checkpoint}
            end;
        _ -> {error, invalid_checkpoint}
    end.

valid_checkpoint_output(Checkpoint) ->
    case maps:find(<<"output">>, Checkpoint) of
        error -> true;
        {ok, Output} -> json_safe_exact(Output)
    end.

checkpoint_map(Compiled, State, Cursor, Steps, Transfers, Completed) ->
    #{<<"schema_version">> => 1,
      <<"workflow_id">> => maps:get(id, Compiled),
      <<"workflow_version">> => maps:get(version, Compiled),
      <<"kind">> => kind_binary(maps:get(kind, Compiled)),
      <<"cursor">> => Cursor,
      <<"state">> => State,
      <<"remaining">> => #{<<"steps">> => Steps,
                            <<"transfers">> => Transfers},
      <<"completed">> => Completed}.

initial_cursor(sequential, _Data) ->
    #{<<"type">> => <<"sequential">>, <<"next_index">> => 1};
initial_cursor(parallel, _Data) ->
    #{<<"type">> => <<"parallel">>, <<"status">> => <<"pending">>};
initial_cursor(loop, _Data) ->
    #{<<"type">> => <<"loop">>, <<"iteration">> => 0};
initial_cursor(transfer, Data) ->
    #{<<"type">> => <<"transfer">>,
      <<"member">> => maps:get(entry, Data),
      <<"input">> => null};
initial_cursor(graph, Data) ->
    #{<<"type">> => <<"graph">>,
      <<"node">> => maps:get(entry, Data),
      <<"phase">> => <<"ready">>,
      <<"visits">> => #{}}.

valid_cursor(sequential, Data,
             #{<<"type">> := <<"sequential">>,
               <<"next_index">> := Index} = Cursor) ->
    is_integer(Index) andalso Index >= 1
    andalso Index =< length(maps:get(steps, Data)) + 1
    andalso valid_sequential_phase(Index, Cursor, Data);
valid_cursor(parallel, _Data,
             #{<<"type">> := <<"parallel">>,
               <<"status">> := <<"pending">>}) -> true;
valid_cursor(loop, Data,
             #{<<"type">> := <<"loop">>,
               <<"iteration">> := Iteration}) ->
    is_integer(Iteration) andalso Iteration >= 0
    andalso Iteration =< maps:get(max_iterations, Data);
valid_cursor(transfer, Data,
             #{<<"type">> := <<"transfer">>,
               <<"member">> := Member,
               <<"input">> := _Input}) ->
    is_binary(Member) andalso maps:is_key(Member, maps:get(members, Data));
valid_cursor(graph, Data,
             #{<<"type">> := <<"graph">>, <<"node">> := Node} = Cursor) ->
    valid_graph_cursor(Node, Cursor, Data);
valid_cursor(_, _, _) -> false.

valid_sequential_phase(_Index, Cursor, _Data)
  when not is_map_key(<<"phase">>, Cursor) -> true;
valid_sequential_phase(Index, Cursor, Data) ->
    Steps = maps:get(steps, Data),
    case maps:get(<<"phase">>, Cursor) of
        <<"awaiting_resume">> when Index =< length(Steps) ->
            Step = lists:nth(Index, Steps),
            case maps:get(run, Step) of
                {workflow, _Child, _Opts} ->
                    is_map(maps:get(<<"pause">>, Cursor, undefined))
                    andalso is_map(
                              maps:get(<<"nested_checkpoint">>, Cursor,
                                       undefined))
                    andalso json_safe_exact(Cursor);
                _ -> false
            end;
        _ -> false
    end.

valid_graph_cursor(Node, Cursor, Data) ->
    Nodes = maps:get(nodes, Data),
    Phase = maps:get(<<"phase">>, Cursor, <<"ready">>),
    Visits = maps:get(<<"visits">>, Cursor, #{}),
    is_binary(Node) andalso maps:is_key(Node, Nodes)
    andalso json_safe_exact(Cursor)
    andalso valid_graph_visits(Visits, Nodes)
    andalso case Phase of
        <<"ready">> -> true;
        <<"routing">> ->
            case maps:get(<<"route_target">>, Cursor, undefined) of
                undefined -> true;
                Target -> graph_target_exists(Target, Nodes)
            end;
        <<"awaiting_resume">> ->
            valid_graph_pause_cursor(Node, Cursor, Nodes);
        <<"fork">> -> valid_fork_cursor(Node, Cursor, Nodes);
        _ -> false
    end.

valid_graph_visits(Visits, Nodes) when is_map(Visits) ->
    maps:fold(
      fun(Id, Count, Valid) ->
              Valid andalso is_binary(Id) andalso maps:is_key(Id, Nodes)
              andalso is_integer(Count) andalso Count >= 0
              andalso valid_graph_visit_count(Id, Count, Nodes)
      end, true, Visits);
valid_graph_visits(_, _) -> false.

valid_graph_visit_count(Id, Count, Nodes) ->
    case maps:get(Id, Nodes) of
        #{type := loop, max_iterations := Max} -> Count =< Max;
        _ -> Count =:= 0
    end.

valid_graph_pause_cursor(NodeId, Cursor, Nodes) ->
    PauseValid = is_map(maps:get(<<"pause">>, Cursor, undefined)),
    case maps:get(<<"resume_kind">>, Cursor, <<"node">>) of
        <<"node">> ->
            PauseValid andalso graph_node_requires_edge(
                                  maps:get(NodeId, Nodes));
        <<"nested_workflow">> ->
            PauseValid andalso
            maps:get(type, maps:get(NodeId, Nodes), action) =:= workflow
            andalso is_map(maps:get(<<"nested_checkpoint">>, Cursor,
                                    undefined));
        <<"fork_nested_workflow">> ->
            PauseValid andalso
            valid_fork_nested_pause_cursor(NodeId, Cursor, Nodes);
        <<"fork_branch">> ->
            PauseValid andalso valid_fork_pause_cursor(NodeId, Cursor, Nodes);
        _ -> false
    end.

valid_fork_nested_pause_cursor(NodeId, Cursor, Nodes) ->
    Results = maps:get(<<"fork_results">>, Cursor, undefined),
    ForkCursor = Cursor#{<<"phase">> => <<"fork">>,
                         <<"results">> => Results},
    BaseValid = valid_fork_cursor(NodeId, ForkCursor, Nodes),
    ForkNode = maps:get(NodeId, Nodes),
    case {maps:find(<<"paused_branch">>, Cursor),
          maps:find(<<"nested_checkpoint">>, Cursor)} of
        {{ok, BranchId}, {ok, ChildCheckpoint}} ->
            BaseValid andalso is_binary(BranchId)
            andalso lists:member(BranchId, maps:get(branches, ForkNode))
            andalso maps:get(type, maps:get(BranchId, Nodes), action)
                        =:= workflow
            andalso is_map(ChildCheckpoint);
        _ -> false
    end.

valid_fork_pause_cursor(NodeId, Cursor, Nodes) ->
    Results = maps:get(<<"fork_results">>, Cursor, undefined),
    ForkCursor = Cursor#{<<"phase">> => <<"fork">>,
                         <<"results">> => Results},
    BaseValid = valid_fork_cursor(NodeId, ForkCursor, Nodes),
    case {maps:find(<<"paused_branch">>, Cursor),
          maps:find(<<"paused_delta">>, Cursor)} of
        {error, error} -> BaseValid;
        {{ok, BranchId}, {ok, Delta}} ->
            BaseValid andalso is_binary(BranchId)
            andalso lists:member(
                      BranchId,
                      maps:get(branches, maps:get(NodeId, Nodes)))
            andalso is_map(Delta);
        _ -> false
    end.

valid_fork_cursor(NodeId, Cursor, Nodes) ->
    Node = maps:get(NodeId, Nodes),
    Results = maps:get(<<"results">>, Cursor, undefined),
    case {maps:get(type, Node, action), Results} of
        {fork, Value} when is_map(Value) ->
            Branches = maps:get(branches, Node),
            maps:fold(
              fun(Id, Result, Valid) ->
                      Valid andalso lists:member(Id, Branches)
                      andalso valid_fork_result(Result)
              end, true, Value);
        _ -> false
    end.

valid_fork_result(#{<<"result_version">> := 1,
                    <<"output">> := _Output,
                    <<"delta">> := Delta}) -> is_map(Delta);
valid_fork_result(LegacyDelta) -> is_map(LegacyDelta).

json_safe_exact(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} -> true;
        _ -> false
    end.

prepare_resume_checkpoint(#{kind := Kind}, Checkpoint, Opts)
  when Kind =:= graph; Kind =:= sequential ->
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    case maps:get(<<"phase">>, Cursor, <<"ready">>) of
        <<"awaiting_resume">> ->
            case maps:find(resume_input, Opts) of
                error -> {error, resume_input_required};
                {ok, Input} ->
                    case adk_json:normalize(Input) of
                        {ok, SafeInput} ->
                            {ok, Checkpoint#{
                                   <<"cursor">> =>
                                       Cursor#{<<"resume_input">> =>
                                                   SafeInput}}};
                        {error, Reason} ->
                            {error, {invalid_resume_input,
                                     external_reason(
                                       adk_workflow, resume_input, Reason)}}
                    end
            end;
        _ -> {ok, Checkpoint}
    end;
prepare_resume_checkpoint(_Compiled, Checkpoint, _Opts) ->
    {ok, Checkpoint}.

%% Compilation

validate_header(1, Id, Kind0) ->
    case valid_id(Id) of
        false -> invalid([id], expected_nonempty_utf8_binary);
        true ->
            case normalize_kind(Kind0) of
                {ok, Kind} -> {ok, Kind};
                error -> invalid([kind], unsupported_kind)
            end
    end;
validate_header(_Version, _Id, _Kind) ->
    invalid([version], unsupported_version).

compile_kind(sequential, Spec) ->
    case compile_named_actions(get_field(steps, Spec, undefined), steps) of
        {ok, Steps} when Steps =/= [] ->
            {ok, #{steps => Steps,
                   max_steps => positive_default(
                                  get_field(max_steps, Spec,
                                            ?DEFAULT_MAX_STEPS),
                                  [max_steps])}};
        {ok, []} -> invalid([steps], empty);
        {error, _} = Error -> Error
    end;
compile_kind(parallel, Spec) ->
    case compile_named_actions(get_field(branches, Spec, undefined),
                               branches) of
        {ok, Branches} when Branches =/= [] ->
            Merge = get_field(merge, Spec, reject_conflicts),
            MaxConcurrency = get_field(max_concurrency, Spec,
                                       erlang:max(1,
                                         erlang:system_info(schedulers_online))),
            case {compile_merge(Merge), positive(MaxConcurrency)} of
                {{ok, CompiledMerge}, true} ->
                    {ok, #{branches => Branches,
                           merge => CompiledMerge,
                           max_concurrency => MaxConcurrency,
                           max_steps => positive_default(
                                          get_field(max_steps, Spec,
                                                    ?DEFAULT_MAX_STEPS),
                                          [max_steps])}};
                {{error, _} = Error, _} -> Error;
                {_, false} -> invalid([max_concurrency], expected_positive_integer)
            end;
        {ok, []} -> invalid([branches], empty);
        {error, _} = Error -> Error
    end;
compile_kind(loop, Spec) ->
    Body = get_field(body, Spec, undefined),
    Until = get_field(until, Spec, undefined),
    MaxIterations = get_field(max_iterations, Spec, undefined),
    case {compile_action(Body), compile_predicate(Until),
          valid_non_neg(MaxIterations)} of
        {{ok, Body1}, {ok, Until1}, true} ->
            {ok, #{body => #{id => <<"loop-body">>, run => Body1},
                   until => Until1,
                   max_iterations => MaxIterations,
                   max_steps => positive_default(
                                  get_field(max_steps, Spec,
                                            ?DEFAULT_MAX_STEPS),
                                  [max_steps])}};
        {{error, _}, _, _} -> invalid([body], invalid_action);
        {_, {error, _}, _} -> invalid([until], invalid_predicate);
        {_, _, false} -> invalid([max_iterations], expected_non_negative_integer)
    end;
compile_kind(transfer, Spec) ->
    Entry = get_field(entry, Spec, undefined),
    Members0 = get_field(members, Spec, undefined),
    MaxTransfers = get_field(max_transfers, Spec, ?DEFAULT_MAX_TRANSFERS),
    case {compile_members(Members0), valid_non_neg(MaxTransfers)} of
        {{ok, Members}, true} when map_size(Members) > 0 ->
            case is_binary(Entry) andalso maps:is_key(Entry, Members) of
                true ->
                    {ok, #{entry => Entry,
                           members => Members,
                           max_transfers => MaxTransfers,
                           max_steps => positive_default(
                                          get_field(max_steps, Spec,
                                                    ?DEFAULT_MAX_STEPS),
                                          [max_steps])}};
                false -> invalid([entry], unknown_transfer_entry)
            end;
        {{ok, _}, true} -> invalid([members], empty);
        {{error, _} = Error, _} -> Error;
        {_, false} -> invalid([max_transfers], expected_non_negative_integer)
    end;
compile_kind(graph, Spec) ->
    Entry = get_field(entry, Spec, undefined),
    Nodes0 = get_field(nodes, Spec, undefined),
    Edges0 = get_field(edges, Spec, undefined),
    case compile_graph_nodes(Nodes0) of
        {ok, NodeList} when NodeList =/= [] ->
            Nodes = maps:from_list([{maps:get(id, Node), Node}
                                    || Node <- NodeList]),
            case is_binary(Entry) andalso maps:is_key(Entry, Nodes) of
                false -> invalid([entry], unknown_graph_entry);
                true ->
                    case compile_edges(Edges0, Nodes) of
                        {ok, Edges} ->
                            case validate_graph_nodes(Nodes, Edges) of
                                ok ->
                                    {ok, #{entry => Entry,
                                           nodes => Nodes,
                                           node_order => [maps:get(id, N)
                                                          || N <- NodeList],
                                           edges => Edges,
                                           max_steps => positive_default(
                                                          get_field(
                                                            max_steps, Spec,
                                                            ?DEFAULT_MAX_STEPS),
                                                          [max_steps])}};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        {ok, []} -> invalid([nodes], empty);
        {error, _} = Error -> Error
    end.

compile_workflow_schemas(Spec) ->
    Input0 = get_field(input_schema, Spec, undefined),
    Output0 = get_field(output_schema, Spec, undefined),
    case {adk_json_schema:compile(Input0),
          adk_json_schema:compile(Output0)} of
        {{ok, Input}, {ok, Output}} -> {ok, Input, Output};
        {{error, Reason}, _} -> invalid([input_schema], Reason);
        {_, {error, Reason}} -> invalid([output_schema], Reason)
    end.

compile_graph_nodes(Value) when is_list(Value) ->
    compile_graph_nodes(Value, 1, [], #{});
compile_graph_nodes(_Value) ->
    invalid([nodes], expected_list).

compile_graph_nodes([], _Index, Acc, _Seen) ->
    {ok, lists:reverse(Acc)};
compile_graph_nodes([Item | Rest], Index, Acc, Seen) when is_map(Item) ->
    Id = get_field(id, Item, undefined),
    case valid_id(Id) of
        false -> invalid([nodes, Index, id], expected_nonempty_utf8_binary);
        true ->
            case maps:is_key(Id, Seen) of
                true -> invalid([nodes, Index, id], {duplicate_id, Id});
                false ->
                    case compile_graph_node(Item, Index, Id) of
                        {ok, Node} ->
                            compile_graph_nodes(Rest, Index + 1,
                                                [Node | Acc],
                                                Seen#{Id => true});
                        {error, _} = Error -> Error
                    end
            end
    end;
compile_graph_nodes([_ | _], Index, _Acc, _Seen) ->
    invalid([nodes, Index], expected_map).

compile_graph_node(Item, Index, Id) ->
    Type0 = get_field(type, Item, action),
    case normalize_graph_node_type(Type0) of
        action ->
            compile_graph_action_node(Item, Index, Id, action,
                                      get_field(run, Item, undefined));
        agent ->
            Name = get_field(agent, Item, get_field(name, Item, undefined)),
            Prompt = get_field(prompt, Item, undefined),
            Decide = get_field(decide, Item, undefined),
            compile_graph_action_node(Item, Index, Id, agent,
                                      {agent, Name, Prompt, Decide});
        tool -> compile_graph_tool_node(Item, Index, Id);
        workflow -> compile_graph_workflow_node(Item, Index, Id);
        branch -> compile_graph_router_node(Item, Index, Id, branch);
        dynamic -> compile_graph_router_node(Item, Index, Id, dynamic);
        loop -> compile_graph_loop_node(Item, Index, Id);
        fork -> compile_graph_fork_node(Item, Index, Id);
        join ->
            case get_field(run, Item, undefined) of
                undefined -> {ok, #{id => Id, type => join, run => noop}};
                Action ->
                    compile_graph_action_node(Item, Index, Id, join, Action)
            end;
        error -> invalid([nodes, Index, type], unsupported_graph_node_type)
    end.

compile_graph_action_node(Item, Index, Id, Type, Action) ->
    case {compile_action(Action), compile_action_policy(Item)} of
        {{ok, CompiledAction}, {ok, Policy}} ->
            {ok, #{id => Id, type => Type, run => CompiledAction,
                   policy => Policy}};
        {{error, _}, _} -> invalid([nodes, Index, run], invalid_action);
        {_, {error, Reason}} -> invalid([nodes, Index, policy], Reason)
    end.

compile_graph_tool_node(Item, Index, Id) ->
    Module = get_field(module, Item, undefined),
    Args = get_field(args, Item, #{}),
    ResultKey = get_field(result_key, Item, undefined),
    ArgsValid = is_map(Args) orelse is_function(Args, 1)
        orelse is_function(Args, 2) orelse valid_mfa(Args),
    ResultValid = ResultKey =:= undefined orelse valid_id(ResultKey),
    case {is_atom(Module) andalso ArgsValid andalso ResultValid,
          compile_action_policy(Item)} of
        {true, {ok, Policy}} ->
            {ok, #{id => Id, type => tool,
                   run => {tool, Module, Args, ResultKey},
                   policy => Policy}};
        {false, _} -> invalid([nodes, Index], invalid_tool_node);
        {_, {error, Reason}} -> invalid([nodes, Index, policy], Reason)
    end.

compile_graph_workflow_node(Item, Index, Id) ->
    Workflow = get_field(workflow, Item, undefined),
    Opts = get_field(options, Item, #{}),
    case {is_compiled(Workflow) andalso valid_nested_workflow_options(Opts),
          compile_action_policy(Item)} of
        {true, {ok, Policy}} ->
            {ok, #{id => Id, type => workflow,
                   run => {workflow, Workflow, Opts}, policy => Policy}};
        {false, _} -> invalid([nodes, Index], invalid_nested_workflow_node);
        {_, {error, Reason}} -> invalid([nodes, Index, policy], Reason)
    end.

valid_nested_workflow_options(Opts) when is_map(Opts) ->
    Allowed = [timeout, max_steps, max_transfers, max_concurrency,
               retention_ms, event_receiver],
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Opts))
    andalso valid_nested_timeout(maps:get(timeout, Opts, 30000))
    andalso positive(maps:get(max_steps, Opts, 1))
    andalso valid_non_neg(maps:get(max_transfers, Opts, 0))
    andalso positive(maps:get(max_concurrency, Opts, 1))
    andalso valid_non_neg(maps:get(retention_ms, Opts, 0))
    andalso valid_nested_receiver(maps:get(event_receiver, Opts, undefined));
valid_nested_workflow_options(_) -> false.

valid_nested_timeout(infinity) -> true;
valid_nested_timeout(Value) -> valid_non_neg(Value).

valid_nested_receiver(undefined) -> true;
valid_nested_receiver(Value) -> is_pid(Value).

compile_graph_router_node(Item, Index, Id, Type) ->
    Choose = get_field(choose, Item, get_field(route, Item, undefined)),
    Targets = get_field(targets, Item, undefined),
    case {compile_predicate(Choose), compile_target_list(Targets)} of
        {{ok, CompiledChoose}, {ok, CompiledTargets}} ->
            {ok, #{id => Id, type => Type, choose => CompiledChoose,
                   targets => CompiledTargets}};
        {{error, _}, _} -> invalid([nodes, Index, choose], invalid_route);
        {_, {error, Reason}} -> invalid([nodes, Index, targets], Reason)
    end.

compile_graph_loop_node(Item, Index, Id) ->
    Decide = get_field(while, Item, get_field(decide, Item, undefined)),
    Body = get_field(body, Item, undefined),
    Done = get_field(done, Item, end_node),
    Max = get_field(max_iterations, Item, undefined),
    case {compile_predicate(Decide), valid_id(Body),
          valid_graph_target_id(Done), valid_non_neg(Max)} of
        {{ok, CompiledDecide}, true, true, true} ->
            {ok, #{id => Id, type => loop, decide => CompiledDecide,
                   body => Body, done => Done, max_iterations => Max}};
        {{error, _}, _, _, _} ->
            invalid([nodes, Index, while], invalid_predicate);
        {_, false, _, _} -> invalid([nodes, Index, body], invalid_target);
        {_, _, false, _} -> invalid([nodes, Index, done], invalid_target);
        {_, _, _, false} ->
            invalid([nodes, Index, max_iterations],
                    expected_non_negative_integer)
    end.

compile_graph_fork_node(Item, Index, Id) ->
    Branches = get_field(branches, Item, undefined),
    Join = get_field(join, Item, undefined),
    Merge = get_field(merge, Item, reject_conflicts),
    Max = get_field(max_concurrency, Item,
                    erlang:max(1, erlang:system_info(schedulers_online))),
    case {compile_id_list(Branches), valid_id(Join), compile_merge(Merge),
          positive(Max)} of
        {{ok, CompiledBranches}, true, {ok, CompiledMerge}, true}
          when CompiledBranches =/= [] ->
            {ok, #{id => Id, type => fork, branches => CompiledBranches,
                   join => Join, merge => CompiledMerge,
                   max_concurrency => Max}};
        {{ok, []}, _, _, _} -> invalid([nodes, Index, branches], empty);
        {{error, Reason}, _, _, _} ->
            invalid([nodes, Index, branches], Reason);
        {_, false, _, _} -> invalid([nodes, Index, join], invalid_target);
        {_, _, {error, _}, _} -> invalid([nodes, Index, merge], invalid_merge_policy);
        {_, _, _, false} ->
            invalid([nodes, Index, max_concurrency], expected_positive_integer)
    end.

compile_target_list(Targets) when is_list(Targets), Targets =/= [] ->
    case lists:all(fun valid_graph_target_id/1, Targets) of
        true ->
            case length(lists:usort(Targets)) =:= length(Targets) of
                true -> {ok, Targets};
                false -> {error, duplicate_target}
            end;
        false -> {error, invalid_target}
    end;
compile_target_list([]) -> {error, empty};
compile_target_list(_) -> {error, expected_list}.

compile_id_list(Ids) when is_list(Ids) ->
    case lists:all(fun valid_id/1, Ids) of
        false -> {error, invalid_id};
        true ->
            case length(lists:usort(Ids)) =:= length(Ids) of
                true -> {ok, Ids};
                false -> {error, duplicate_id}
            end
    end;
compile_id_list(_) -> {error, expected_list}.

valid_graph_target_id(end_node) -> true;
valid_graph_target_id(<<"$end">>) -> true;
valid_graph_target_id(Value) -> valid_id(Value).

normalize_graph_node_type(action) -> action;
normalize_graph_node_type(agent) -> agent;
normalize_graph_node_type(tool) -> tool;
normalize_graph_node_type(workflow) -> workflow;
normalize_graph_node_type(branch) -> branch;
normalize_graph_node_type(dynamic) -> dynamic;
normalize_graph_node_type(loop) -> loop;
normalize_graph_node_type(fork) -> fork;
normalize_graph_node_type(join) -> join;
normalize_graph_node_type(<<"action">>) -> action;
normalize_graph_node_type(<<"agent">>) -> agent;
normalize_graph_node_type(<<"tool">>) -> tool;
normalize_graph_node_type(<<"workflow">>) -> workflow;
normalize_graph_node_type(<<"branch">>) -> branch;
normalize_graph_node_type(<<"dynamic">>) -> dynamic;
normalize_graph_node_type(<<"loop">>) -> loop;
normalize_graph_node_type(<<"fork">>) -> fork;
normalize_graph_node_type(<<"join">>) -> join;
normalize_graph_node_type(_) -> error.

compile_named_actions(Value, Field) when is_list(Value) ->
    compile_named_actions(Value, Field, 1, [], #{});
compile_named_actions(_Value, Field) ->
    invalid([Field], expected_list).

compile_named_actions([], _Field, _Index, Acc, _Seen) ->
    {ok, lists:reverse(Acc)};
compile_named_actions([Item | Rest], Field, Index, Acc, Seen)
  when is_map(Item) ->
    Id = get_field(id, Item, undefined),
    Action = get_field(run, Item, undefined),
    case valid_id(Id) of
        false -> invalid([Field, Index, id], expected_nonempty_utf8_binary);
        true ->
            case maps:is_key(Id, Seen) of
                true -> invalid([Field, Index, id], {duplicate_id, Id});
                false ->
                    case compile_action(Action) of
                        {ok, CompiledAction} ->
                            case compile_action_policy(Item) of
                                {ok, Policy} ->
                                    compile_named_actions(
                                      Rest, Field, Index + 1,
                                      [#{id => Id, run => CompiledAction,
                                         policy => Policy} | Acc],
                                      Seen#{Id => true});
                                {error, Reason} ->
                                    invalid([Field, Index, policy], Reason)
                            end;
                        {error, _} -> invalid([Field, Index, run], invalid_action)
                    end
            end
    end;
compile_named_actions([_ | _], Field, Index, _Acc, _Seen) ->
    invalid([Field, Index], expected_map).

compile_members(Members) when is_map(Members) ->
    maps:fold(
      fun(Id, Member, {ok, Acc}) when is_binary(Id), is_map(Member) ->
              case valid_id(Id) of
                  false -> invalid([members, Id], invalid_member_id);
                  true ->
                      case {compile_action(
                              get_field(run, Member, undefined)),
                            compile_action_policy(Member)} of
                          {{ok, Action}, {ok, Policy}} ->
                              {ok, Acc#{Id => #{id => Id, run => Action,
                                                policy => Policy}}};
                          {{error, _}, _} ->
                              invalid([members, Id, run], invalid_action);
                          {_, {error, Reason}} ->
                              invalid([members, Id, policy], Reason)
                      end
              end;
         (_Id, _Member, {ok, _Acc}) ->
              invalid([members], invalid_member);
         (_Id, _Member, Error) -> Error
      end, {ok, #{}}, Members);
compile_members(_) ->
    invalid([members], expected_map).

compile_edges(Edges, Nodes) when is_map(Edges) ->
    Required = [Id || {Id, Node} <- maps:to_list(Nodes),
                      graph_node_requires_edge(Node)],
    case lists:sort(maps:keys(Edges)) =:= lists:sort(Required) of
        false -> invalid([edges], every_node_requires_explicit_edge);
        true ->
            maps:fold(
              fun(From, Edge, {ok, Acc}) ->
                      case maps:is_key(From, Nodes) of
                          false -> invalid([edges, From], unknown_edge_source);
                          true ->
                              case compile_edge(Edge, Nodes) of
                                  {ok, CompiledEdge} ->
                                      {ok, Acc#{From => CompiledEdge}};
                                  {error, Reason} ->
                                      invalid([edges, From], Reason)
                              end
                      end;
                 (_From, _Edge, Error) -> Error
              end, {ok, #{}}, Edges)
    end;
compile_edges(_, _Nodes) ->
    invalid([edges], expected_map).

graph_node_requires_edge(#{type := Type}) ->
    lists:member(Type, [action, agent, tool, workflow, join]).

compile_edge(end_node, _Nodes) -> {ok, end_node};
compile_edge(Target, Nodes) when is_binary(Target) ->
    case maps:is_key(Target, Nodes) of
        true -> {ok, Target};
        false -> {error, {unknown_edge_target, Target}}
    end;
compile_edge({route, Predicate}, _Nodes) ->
    case compile_predicate(Predicate) of
        {ok, Route} -> {ok, {route, Route}};
        {error, _} -> {error, invalid_route}
    end;
compile_edge(Predicate, _Nodes) when is_function(Predicate, 1);
                                         is_function(Predicate, 2) ->
    {ok, {route, Predicate}};
compile_edge(_Edge, _Nodes) ->
    {error, invalid_edge}.

validate_graph_nodes(Nodes, Edges) ->
    maps:fold(
      fun(_Id, _Node, {error, _} = Error) -> Error;
         (Id, Node, ok) -> validate_graph_node(Id, Node, Nodes, Edges)
      end, ok, Nodes).

validate_graph_node(Id, #{type := fork} = Node, Nodes, Edges) ->
    Branches = maps:get(branches, Node),
    Join = maps:get(join, Node),
    case maps:is_key(Join, Nodes)
         andalso lists:all(
                   fun(BranchId) ->
                           case maps:find(BranchId, Nodes) of
                               {ok, BranchNode} ->
                                   BranchId =/= Id andalso BranchId =/= Join
                                   andalso graph_fork_branch(BranchNode)
                                   andalso maps:get(BranchId, Edges,
                                                    undefined) =:= Join;
                               error -> false
                           end
                   end, Branches) of
        true -> ok;
        false -> invalid([nodes, Id], invalid_fork_topology)
    end;
validate_graph_node(Id, #{type := Type, targets := Targets}, Nodes, _Edges)
  when Type =:= branch; Type =:= dynamic ->
    case lists:all(fun(Target) -> graph_target_exists(Target, Nodes) end,
                   Targets) of
        true -> ok;
        false -> invalid([nodes, Id, targets], unknown_graph_target)
    end;
validate_graph_node(Id, #{type := loop, body := Body, done := Done},
                    Nodes, _Edges) ->
    case graph_target_exists(Body, Nodes)
         andalso graph_target_exists(Done, Nodes) of
        true -> ok;
        false -> invalid([nodes, Id], unknown_graph_target)
    end;
validate_graph_node(_Id, _Node, _Nodes, _Edges) -> ok.

graph_fork_branch(#{type := Type}) ->
    lists:member(Type, [action, agent, tool, workflow]).

graph_target_exists(end_node, _Nodes) -> true;
graph_target_exists(<<"$end">>, _Nodes) -> true;
graph_target_exists(Target, Nodes) when is_binary(Target) ->
    maps:is_key(Target, Nodes);
graph_target_exists(_, _) -> false.

compile_action(Action) when is_function(Action, 1);
                            is_function(Action, 2) ->
    {ok, Action};
compile_action({agent, Name, Prompt}) ->
    compile_agent_action(Name, Prompt, undefined);
compile_action({agent, Name, Prompt, Decide}) ->
    compile_agent_action(Name, Prompt, Decide);
compile_action({tool, Module, Args, ResultKey})
  when is_atom(Module),
       (is_map(Args) orelse is_function(Args, 1)
        orelse is_function(Args, 2)) ->
    case ResultKey =:= undefined orelse valid_id(ResultKey) of
        true -> {ok, {tool, Module, Args, ResultKey}};
        false -> {error, invalid_tool_action}
    end;
compile_action({workflow, Compiled, Opts}) when is_map(Opts) ->
    case is_compiled(Compiled) of
        true -> {ok, {workflow, Compiled, Opts}};
        false -> {error, invalid_nested_workflow}
    end;
compile_action({Module, Function, ExtraArgs})
  when is_atom(Module), is_atom(Function), is_list(ExtraArgs) ->
    {ok, {Module, Function, ExtraArgs}};
compile_action(_) ->
    {error, invalid_action}.

compile_action_policy(Item) ->
    Timeout = get_field(timeout, Item, infinity),
    Retry = get_field(retry, Item, #{}),
    case {valid_action_timeout(Timeout), compile_retry_policy(Retry)} of
        {true, {ok, RetryPolicy}} ->
            {ok, RetryPolicy#{timeout => Timeout}};
        {false, _} -> {error, invalid_timeout};
        {_, {error, Reason}} -> {error, Reason}
    end.

valid_action_timeout(infinity) -> true;
valid_action_timeout(Value) -> valid_non_neg(Value).

compile_retry_policy(Retry) when is_map(Retry) ->
    Allowed = [max_attempts, backoff_ms,
               <<"max_attempts">>, <<"backoff_ms">>],
    MaxAttempts = get_field(max_attempts, Retry, 1),
    BackoffMs = get_field(backoff_ms, Retry, 0),
    case {lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                    maps:keys(Retry)),
          positive(MaxAttempts), valid_non_neg(BackoffMs)} of
        {true, true, true} ->
            {ok, #{max_attempts => MaxAttempts,
                   backoff_ms => BackoffMs}};
        {false, _, _} -> {error, invalid_retry_option};
        {_, false, _} -> {error, invalid_retry_max_attempts};
        {_, _, false} -> {error, invalid_retry_backoff}
    end;
compile_retry_policy(_) -> {error, invalid_retry_policy}.

compile_agent_action(Name, Prompt, Decide) ->
    PromptValid = is_binary(Prompt)
        orelse is_list(Prompt)
        orelse is_function(Prompt, 1)
        orelse is_function(Prompt, 2)
        orelse valid_mfa(Prompt),
    DecideValid = Decide =:= undefined
        orelse is_function(Decide, 2)
        orelse is_function(Decide, 3)
        orelse valid_mfa(Decide),
    case {adk_agent_tree:validate_name(Name), PromptValid, DecideValid} of
        {{ok, CanonicalName}, true, true} ->
            {ok, {agent, CanonicalName, Prompt, Decide}};
        _ ->
            {error, invalid_agent_action}
    end.

valid_mfa({Module, Function, ExtraArgs}) ->
    is_atom(Module) andalso is_atom(Function) andalso is_list(ExtraArgs);
valid_mfa(_) -> false.

compile_predicate(Predicate) when is_function(Predicate, 1);
                                  is_function(Predicate, 2) ->
    {ok, Predicate};
compile_predicate({Module, Function, ExtraArgs})
  when is_atom(Module), is_atom(Function), is_list(ExtraArgs) ->
    {ok, {Module, Function, ExtraArgs}};
compile_predicate(_) ->
    {error, invalid_predicate}.

compile_merge(reject_conflicts) -> {ok, reject_conflicts};
compile_merge(ordered_last_wins) -> {ok, ordered_last_wins};
compile_merge({custom, Fun}) when is_function(Fun, 2) ->
    {ok, {custom, Fun}};
compile_merge(_) -> invalid([merge], invalid_merge_policy).

%% Public checkpoint builder used by the execution engine.
%% Kept as a local convention: the engine updates this map directly rather
%% than exposing Erlang control terms in a checkpoint.

%% Pause reason/summary values are user-facing workflow data, not failures.
%% Bound their shape for JSON checkpoint compatibility; failure paths use the
%% structural helpers below and never retain application/provider payloads.
sanitize_reason(Reason) ->
    sanitize_reason(Reason, 0).

%% External failures cross a trust boundary. Safe atom tags retain useful
%% control-flow compatibility; every other payload is classified into the
%% bounded structural adk_failure envelope without retaining source data.
external_reason(_Component, _Operation,
                Failure = {adk_failure, Metadata}) when is_map(Metadata) ->
    Failure;
external_reason(_Component, _Operation, Reason) when is_atom(Reason) ->
    Reason;
external_reason(Component, Operation, Reason) ->
    adk_failure:external(Component, Operation, Reason).

exception_reason(Component, Operation, Class, Reason) ->
    adk_failure:exception(Component, Operation, Class, Reason).

%% Preserve stable workflow topology tags while replacing any untrusted leaf.
%% This keeps outcomes operationally useful (which step/branch/node failed)
%% without copying provider bodies, exception arguments, or application maps.
failure_reason(Failure = {adk_failure, Metadata}) when is_map(Metadata) ->
    Failure;
failure_reason(Reason) when is_atom(Reason) ->
    Reason;
failure_reason({action_exception,
                Failure = {adk_failure, Metadata}}) when is_map(Metadata) ->
    {action_exception, Failure};
failure_reason({action_exception, Class, Reason}) ->
    {action_exception,
     exception_reason(adk_workflow_action, execute, Class, Reason)};
failure_reason({engine_exception,
                Failure = {adk_failure, Metadata}}) when is_map(Metadata) ->
    {engine_exception, Failure};
failure_reason({engine_exception, Class, Reason}) ->
    {engine_exception,
     exception_reason(adk_workflow_engine, execute, Class, Reason)};
failure_reason({state_conflict,
                Failure = {adk_failure, Metadata}, Owners})
  when is_map(Metadata) ->
    {state_conflict, Failure, safe_identifiers(Owners)};
failure_reason({state_conflict, Key, Owners}) ->
    {state_conflict,
     adk_failure:external(adk_workflow, state_conflict, #{key => Key}),
     safe_identifiers(Owners)};
failure_reason({budget_exhausted, Budget})
  when Budget =:= steps; Budget =:= transfers; Budget =:= iterations ->
    {budget_exhausted, Budget};
failure_reason({budget_exhausted, {graph_loop_iterations, NodeId}}) ->
    {budget_exhausted, {graph_loop_iterations, safe_identifier(NodeId)}};
failure_reason({resume_input_required, NodeId}) ->
    {resume_input_required, safe_identifier(NodeId)};
failure_reason({action_timed_out, Timeout})
  when Timeout =:= infinity;
       is_integer(Timeout), Timeout >= 0 ->
    {action_timed_out, Timeout};
failure_reason({retry_exhausted, Attempts, Reason})
  when is_integer(Attempts), Attempts > 0 ->
    {retry_exhausted, Attempts, retry_failure_reason(Reason)};
failure_reason({output_schema_validation_failed, Reason}) ->
    {output_schema_validation_failed, schema_failure_reason(Reason)};
failure_reason({Tag, Id, Reason}) ->
    case nested_failure_tag(Tag) of
        true ->
            {Tag, safe_identifier(Id), failure_detail(Tag, Reason)};
        false ->
            adk_failure:external(adk_workflow, execute, {Tag, Id, Reason})
    end;
failure_reason({Tag, Reason}) ->
    case detail_failure_tag(Tag) of
        true -> {Tag, failure_detail(Tag, Reason)};
        false -> adk_failure:external(adk_workflow, execute, {Tag, Reason})
    end;
failure_reason(Reason) ->
    adk_failure:external(adk_workflow, execute, Reason).

retry_failure_reason({action_timed_out, Timeout})
  when Timeout =:= infinity;
       is_integer(Timeout), Timeout >= 0 ->
    {action_timed_out, Timeout};
retry_failure_reason({returned_error, Reason}) when is_atom(Reason) ->
    {returned_error, Reason};
retry_failure_reason({action_exception, _Class, _Reason} = Failure) ->
    failure_reason(Failure);
retry_failure_reason({attempt_worker_down, Failure}) ->
    {attempt_worker_down, failure_reason(Failure)};
retry_failure_reason(Reason) -> failure_reason(Reason).

schema_failure_reason({schema_validation_failed, Path, Constraint}) ->
    {schema_validation_failed, safe_identifiers(Path),
     sanitize_reason(Constraint)};
schema_failure_reason({invalid_json_value, Reason}) ->
    {invalid_json_value, sanitize_reason(Reason)};
schema_failure_reason(Reason) ->
    external_reason(adk_workflow, output_schema, Reason).

terminal_outcome(failed, {failed, Reason, _EmbeddedCheckpoint}, Checkpoint) ->
    {failed, failure_reason(Reason), Checkpoint};
terminal_outcome(failed, Reason, Checkpoint) ->
    {failed, failure_reason(Reason), Checkpoint};
terminal_outcome(cancelled,
                 {cancelled, Reason, _EmbeddedCheckpoint}, Checkpoint) ->
    {cancelled, external_reason(adk_workflow, cancel, Reason), Checkpoint};
terminal_outcome(cancelled, Reason, Checkpoint) ->
    {cancelled, external_reason(adk_workflow, cancel, Reason), Checkpoint};
terminal_outcome(timed_out, _Outcome, Checkpoint) ->
    {timed_out, Checkpoint};
terminal_outcome(_Phase, Outcome, _Checkpoint) ->
    Outcome.

public_invocation_record(Record) when is_map(Record) ->
    Public0 = maps:with(
                [invocation_id, workflow_id, workflow_version, kind,
                 checkpoint, phase, outcome, owned, owner_node, lease_until,
                 revision, created_at, updated_at], Record),
    Phase = maps:get(phase, Public0, undefined),
    Checkpoint = maps:get(checkpoint, Public0, #{}),
    case Phase of
        failed -> Public0#{outcome => terminal_outcome(
                                       failed,
                                       maps:get(outcome, Public0, undefined),
                                       Checkpoint)};
        cancelled -> Public0#{outcome => terminal_outcome(
                                          cancelled,
                                          maps:get(outcome, Public0, undefined),
                                          Checkpoint)};
        _ -> Public0
    end.

nested_failure_tag(step_failed) -> true;
nested_failure_tag(branch_failed) -> true;
nested_failure_tag(member_failed) -> true;
nested_failure_tag(node_failed) -> true;
nested_failure_tag(route_failed) -> true;
nested_failure_tag(graph_loop_failed) -> true;
nested_failure_tag(fork_branch_failed) -> true;
nested_failure_tag(fork_merge_failed) -> true;
nested_failure_tag(_) -> false.

detail_failure_tag(loop_body_failed) -> true;
detail_failure_tag(loop_predicate_failed) -> true;
detail_failure_tag(action_exception) -> true;
detail_failure_tag(engine_exception) -> true;
detail_failure_tag(merge_failed) -> true;
detail_failure_tag(invalid_output) -> true;
detail_failure_tag(invalid_pause_reason) -> true;
detail_failure_tag(invalid_pause_summary) -> true;
detail_failure_tag(invalid_state_delta) -> true;
detail_failure_tag(invalid_tool_args) -> true;
detail_failure_tag(invalid_tool_result) -> true;
detail_failure_tag(invalid_transfer_input) -> true;
detail_failure_tag(invalid_control) -> true;
detail_failure_tag(worker_down) -> true;
detail_failure_tag(agent_error) -> true;
detail_failure_tag(agent_not_found) -> true;
detail_failure_tag(nested_workflow_guardian_down) -> true;
detail_failure_tag(nested_workflow_start_failed) -> true;
detail_failure_tag(nested_workflow_waiter_down) -> true;
detail_failure_tag(nested_workflow_failed) -> true;
detail_failure_tag(nested_workflow_cancelled) -> true;
detail_failure_tag(nested_workflow_paused) -> true;
detail_failure_tag(invalid_nested_workflow_result) -> true;
detail_failure_tag(engine_process_down) -> true;
detail_failure_tag(durable_checkpoint_failed) -> true;
detail_failure_tag(durable_terminal_failed) -> true;
detail_failure_tag(durable_lease_lost) -> true;
detail_failure_tag(invalid_route) -> true;
detail_failure_tag(target_not_allowed) -> true;
detail_failure_tag(unknown_transfer_target) -> true;
detail_failure_tag(_) -> false.

failure_detail(_Tag, Failure = {adk_failure, Metadata}) when is_map(Metadata) ->
    Failure;
failure_detail(_Tag, Reason) when is_atom(Reason) ->
    Reason;
failure_detail(_Tag, Reason) ->
    failure_reason(Reason).

safe_identifier(Value) when is_binary(Value); is_atom(Value);
                            is_integer(Value) -> Value;
safe_identifier(_Value) -> redacted_identifier.

safe_identifiers(Values) when is_list(Values) ->
    safe_identifiers(Values, 16, []);
safe_identifiers(_Values) -> [redacted_identifier].

safe_identifiers(_Values, 0, Acc) -> lists:reverse([truncated | Acc]);
safe_identifiers([], _Remaining, Acc) -> lists:reverse(Acc);
safe_identifiers([Value | Rest], Remaining, Acc) ->
    safe_identifiers(Rest, Remaining - 1,
                     [safe_identifier(Value) | Acc]);
safe_identifiers(_Improper, _Remaining, Acc) ->
    lists:reverse([redacted_identifier | Acc]).

sanitize_reason(_Reason, Depth) when Depth >= 6 ->
    redacted;
sanitize_reason(Value, _Depth)
  when is_atom(Value); is_integer(Value); is_float(Value) ->
    Value;
sanitize_reason(Value, _Depth) when is_binary(Value), byte_size(Value) =< 4096 ->
    Value;
sanitize_reason(Value, _Depth) when is_binary(Value) ->
    <<Prefix:4096/binary, _/binary>> = Value,
    Prefix;
sanitize_reason(Value, Depth) when is_tuple(Value), tuple_size(Value) =< 16 ->
    list_to_tuple([sanitize_reason(Item, Depth + 1)
                   || Item <- tuple_to_list(Value)]);
sanitize_reason(Value, Depth) when is_list(Value) ->
    sanitize_list(Value, Depth + 1, 32, []);
sanitize_reason(Value, Depth) when is_map(Value), map_size(Value) =< 32 ->
    maps:from_list(
      [{sanitize_key(Key), sanitize_reason(Item, Depth + 1)}
       || {Key, Item} <- maps:to_list(Value)]);
sanitize_reason(Value, _Depth) when is_pid(Value) -> {redacted, pid};
sanitize_reason(Value, _Depth) when is_reference(Value) -> {redacted, reference};
sanitize_reason(Value, _Depth) when is_port(Value) -> {redacted, port};
sanitize_reason(Value, _Depth) when is_function(Value) -> {redacted, function};
sanitize_reason(_Value, _Depth) -> redacted.

sanitize_list([], _Depth, _Remaining, Acc) -> lists:reverse(Acc);
sanitize_list(_Rest, _Depth, 0, Acc) -> lists:reverse([truncated | Acc]);
sanitize_list([Head | Tail], Depth, Remaining, Acc) ->
    sanitize_list(Tail, Depth, Remaining - 1,
                  [sanitize_reason(Head, Depth) | Acc]);
sanitize_list(_Improper, _Depth, _Remaining, Acc) ->
    lists:reverse([improper_list | Acc]).

sanitize_key(Key) when is_atom(Key); is_binary(Key); is_integer(Key) -> Key;
sanitize_key(_Key) -> redacted_key.

%% Helpers

durable_options(Opts) ->
    LeaseMs = maps:get(lease_ms, Opts, ?DEFAULT_LEASE_MS),
    Ledger0 = maps:get(
                ledger, Opts,
                application:get_env(erlang_adk,
                                    durable_invocation_ledger, undefined)),
    case {Ledger0, is_integer(LeaseMs) andalso LeaseMs > 0} of
        {undefined, _} -> {error, durable_invocation_ledger_required};
        {{Module, Handle}, true} when is_atom(Module) ->
            Required = [{get, 2}, {create, 4}, {claim, 6}, {renew, 5},
                        {checkpoint, 6}, {finish, 7}, {delete, 2}],
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case lists:all(
                           fun({Function, Arity}) ->
                               erlang:function_exported(Module, Function,
                                                        Arity)
                           end, Required) of
                        true -> {ok, {Module, Handle}, LeaseMs};
                        false -> {error, {invalid_invocation_ledger, Module}}
                    end;
                _ -> {error, {invalid_invocation_ledger, Module}}
            end;
        {{_Module, _Handle}, false} ->
            {error, {invalid_lease_ms,
                     external_reason(adk_workflow, lease_ms, LeaseMs)}};
        {Invalid, _} ->
            {error, {invalid_invocation_ledger,
                     external_reason(adk_workflow, ledger, Invalid)}}
    end.

resume_durable_record(InvocationId, Compiled, Opts, Ledger, LeaseMs,
                      Record) ->
    Expected = {maps:get(id, Compiled), maps:get(version, Compiled),
                maps:get(kind, Compiled)},
    Actual = {maps:get(workflow_id, Record, undefined),
              maps:get(workflow_version, Record, undefined),
              maps:get(kind, Record, undefined)},
    Phase = maps:get(phase, Record, undefined),
    Checkpoint = maps:get(checkpoint, Record, undefined),
    case {Actual =:= Expected, Phase, is_map(Checkpoint)} of
        {false, _, _} -> {error, invocation_workflow_mismatch};
        {true, completed, _} -> {error, invocation_completed};
        {true, _, false} -> {error, invalid_durable_checkpoint};
        {true, _, true} ->
            case validate_checkpoint(Compiled, Checkpoint) of
                {ok, State} ->
                    case prepare_resume_checkpoint(
                           Compiled, Checkpoint, Opts) of
                        {ok, ResumeCheckpoint} ->
                            Durable = #{mode => resume,
                                        invocation_id => InvocationId,
                                        ledger => Ledger,
                                        lease_ms => LeaseMs},
                            start_supervised(
                              Compiled, State,
                              Opts#{resume_checkpoint => ResumeCheckpoint,
                                    ?DURABLE_OPT => Durable});
                        {error, _} = Error -> Error
                    end;
                {error, checkpoint_complete} ->
                    {error, invocation_completed};
                {error, Reason} ->
                    {error, {invalid_durable_checkpoint, Reason}}
            end
    end.

safe_ledger_call(Module, Function, Args) ->
    try apply(Module, Function, Args) of
        Reply -> Reply
    catch
        Class:Reason ->
            {error, exception_reason(adk_workflow_ledger, Function,
                                     Class, Reason)}
    end.

generate_invocation_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    list_to_binary(
      io_lib:format(
        "inv-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff,
         D band 16#3fff bor 16#8000, E])).

safe_call(Pid, Request, Timeout) ->
    try gen_server:call(Pid, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{shutdown, _} -> {error, not_found};
        exit:Reason ->
            {error, {workflow_call_failed,
                     external_reason(adk_workflow, call, Reason)}}
    end.

start_supervised(Compiled, InitialState, Opts) ->
    case validate_workflow_input(Compiled, InitialState, Opts) of
        ok ->
            try adk_workflow_sup:start_workflow(
                  Compiled, InitialState, Opts) of
                {ok, Pid} -> {ok, Pid};
                {ok, Pid, _Info} -> {ok, Pid};
                {error, Reason} ->
                    {error, {workflow_start_failed,
                             external_reason(adk_workflow, start, Reason)}}
            catch
                exit:{noproc, _} ->
                    {error, workflow_supervisor_not_started};
                exit:Reason ->
                    {error, {workflow_start_failed,
                             external_reason(adk_workflow, start, Reason)}}
            end;
        {error, _} = Error -> Error
    end.

validate_workflow_input(_Compiled, _InitialState,
                        #{resume_checkpoint := _}) -> ok;
validate_workflow_input(Compiled, InitialState, _Opts) ->
    Schema = maps:get(input_schema, Compiled, undefined),
    case adk_json_schema:validate_compiled(Schema, InitialState) of
        {ok, _} -> ok;
        {error, Reason} -> {error, {input_schema_validation_failed, Reason}}
    end.

invalid(Path, Reason) ->
    {error, {invalid_workflow, Path, Reason}}.

get_field(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

normalize_kind(sequential) -> {ok, sequential};
normalize_kind(parallel) -> {ok, parallel};
normalize_kind(loop) -> {ok, loop};
normalize_kind(transfer) -> {ok, transfer};
normalize_kind(graph) -> {ok, graph};
normalize_kind(<<"sequential">>) -> {ok, sequential};
normalize_kind(<<"parallel">>) -> {ok, parallel};
normalize_kind(<<"loop">>) -> {ok, loop};
normalize_kind(<<"transfer">>) -> {ok, transfer};
normalize_kind(<<"graph">>) -> {ok, graph};
normalize_kind(_) -> error.

kind_binary(Kind) -> atom_to_binary(Kind, utf8).

valid_id(Value) when is_binary(Value), byte_size(Value) > 0 ->
    case adk_json:normalize(Value) of
        {ok, Value} -> true;
        _ -> false
    end;
valid_id(_) -> false.

positive(Value) -> is_integer(Value) andalso Value > 0.
valid_non_neg(Value) -> is_integer(Value) andalso Value >= 0.

positive_default(Value, _Path) when is_integer(Value), Value > 0 -> Value;
positive_default(_Value, Path) -> erlang:error({invalid_workflow, Path,
                                                expected_positive_integer}).
