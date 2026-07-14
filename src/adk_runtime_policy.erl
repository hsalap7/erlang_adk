%% @doc Fail-closed runtime authorization and byte-budget policy.
%%
%% A compiled policy is an immutable Erlang value. Agent and tool names must
%% be explicitly allowed (or the corresponding allow selector must be `all`),
%% and deny selectors always win. Content and tool arguments are measured at
%% the runtime boundary without retaining their values.
%%
%% Every check returns an immutable, JSON-safe audit decision. Decisions never
%% contain arguments, content, credentials, exception text, pids, references,
%% or functions. They can therefore be appended to an event/audit store by the
%% caller without further redaction.
-module(adk_runtime_policy).

-export([compile/1, describe/1,
         check_agent/3, check_tool/3, check_content/3]).

-define(VERSION, 1).
-define(DEFAULT_MAX_ARGUMENT_BYTES, 65536).
-define(DEFAULT_MAX_CONTENT_BYTES, 1048576).
-define(MAX_NAME_BYTES, 256).
-define(MAX_POLICY_ID_BYTES, 128).

-opaque policy() :: map().
-type decision() :: map().
-type outcome() :: {allow, decision()} | {deny, decision()}.
-export_type([policy/0, decision/0, outcome/0]).

%% @doc Compile and strictly validate a policy.
%%
%% Supported keys are `id`, `agents`, `tools`, `max_argument_bytes`, and
%% `max_content_bytes`. Agent/tool rules are maps with `allow` and `deny`
%% selectors. A selector is `all` or a list of UTF-8 binary names. Omitted
%% allow selectors are empty, which is intentionally fail-closed.
-spec compile(map()) -> {ok, policy()} | {error, term()}.
compile(Options) when is_map(Options) ->
    AllowedKeys = [id, agents, tools,
                   max_argument_bytes, max_content_bytes],
    case maps:without(AllowedKeys, Options) of
        Unknown when map_size(Unknown) > 0 ->
            {error, unsupported_runtime_policy_options};
        _ -> compile_known(Options)
    end;
compile(_Options) ->
    {error, invalid_runtime_policy}.

compile_known(Options) ->
    ArgumentLimit = maps:get(max_argument_bytes, Options,
                             ?DEFAULT_MAX_ARGUMENT_BYTES),
    ContentLimit = maps:get(max_content_bytes, Options,
                            ?DEFAULT_MAX_CONTENT_BYTES),
    case {compile_rules(maps:get(agents, Options, #{}), agents),
          compile_rules(maps:get(tools, Options, #{}), tools),
          valid_limit(ArgumentLimit), valid_limit(ContentLimit)} of
        {{ok, AgentRules}, {ok, ToolRules}, true, true} ->
            Canonical = #{agents => describe_rules(AgentRules),
                          tools => describe_rules(ToolRules),
                          max_argument_bytes => ArgumentLimit,
                          max_content_bytes => ContentLimit},
            Fingerprint = fingerprint(Canonical),
            case policy_id(maps:get(id, Options, undefined), Fingerprint) of
                {ok, PolicyId} ->
                    {ok, #{version => ?VERSION,
                           id => PolicyId,
                           fingerprint => Fingerprint,
                           agents => AgentRules,
                           tools => ToolRules,
                           max_argument_bytes => ArgumentLimit,
                           max_content_bytes => ContentLimit}};
                {error, _} = Error -> Error
            end;
        {{error, Reason}, _, _, _} -> {error, Reason};
        {_, {error, Reason}, _, _} -> {error, Reason};
        {_, _, false, _} -> {error, invalid_max_argument_bytes};
        {_, _, _, false} -> {error, invalid_max_content_bytes}
    end.

%% @doc JSON-safe policy metadata. Names are policy configuration, not
%% runtime argument/content values.
-spec describe(policy()) -> map().
describe(#{version := ?VERSION} = Policy) ->
    #{<<"schema_version">> => ?VERSION,
      <<"id">> => maps:get(id, Policy),
      <<"fingerprint">> => maps:get(fingerprint, Policy),
      <<"agents">> => json_rules(maps:get(agents, Policy)),
      <<"tools">> => json_rules(maps:get(tools, Policy)),
      <<"max_argument_bytes">> => maps:get(max_argument_bytes, Policy),
      <<"max_content_bytes">> => maps:get(max_content_bytes, Policy)};
describe(_Policy) ->
    #{<<"schema_version">> => ?VERSION,
      <<"status">> => <<"invalid">>}.

%% @doc Authorize an agent invocation, then enforce the content budget.
-spec check_agent(policy(), binary(), term()) -> outcome().
check_agent(Policy, AgentId, Content) ->
    safe_check(Policy, <<"agent_invocation">>, AgentId,
               agents, content, Content).

%% @doc Authorize a resolved tool call, then enforce its canonical JSON
%% argument budget. Runner integration must call this only after normal tool
%% resolution, preserving dynamic toolset and plugin precedence.
-spec check_tool(policy(), binary(), term()) -> outcome().
check_tool(Policy, ToolName, Arguments) ->
    safe_check(Policy, <<"tool_call">>, ToolName,
               tools, arguments, Arguments).

%% @doc Enforce the content budget for an already-authorized runtime value,
%% such as a model response or tool result.
-spec check_content(policy(), binary(), term()) -> outcome().
check_content(Policy, Subject, Content) ->
    safe_check(Policy, <<"content">>, Subject,
               none, content, Content).

safe_check(Policy, Operation, Subject0, RulesKey, BudgetKind, Value) ->
    case valid_policy(Policy) of
        false ->
            Decision = fallback_decision(Operation, Subject0, BudgetKind,
                                         <<"invalid_policy">>),
            emit(Decision),
            {deny, Decision};
        true ->
            try do_check(Policy, Operation, Subject0,
                         RulesKey, BudgetKind, Value)
            catch
                _:_ ->
                    Decision = decision(
                                 Policy, Operation, safe_subject(Subject0),
                                 <<"deny">>, <<"policy_evaluation_failed">>,
                                 BudgetKind, null, budget_limit(Policy,
                                                                BudgetKind)),
                    emit(Decision),
                    {deny, Decision}
            end
    end.

do_check(Policy, Operation, Subject0, RulesKey, BudgetKind, Value) ->
    case normalize_subject(Subject0) of
        error ->
            finish(deny, Policy, Operation, <<"<invalid>">>,
                   <<"invalid_subject">>, BudgetKind, null,
                   budget_limit(Policy, BudgetKind));
        {ok, Subject} ->
            case authorize(RulesKey, Subject, Policy) of
                {deny, Reason} ->
                    finish(deny, Policy, Operation, Subject, Reason,
                           BudgetKind, null,
                           budget_limit(Policy, BudgetKind));
                allow ->
                    check_budget(Policy, Operation, Subject,
                                 BudgetKind, Value)
            end
    end.

check_budget(Policy, Operation, Subject, BudgetKind, Value) ->
    Limit = budget_limit(Policy, BudgetKind),
    case measured_bytes(BudgetKind, Value) of
        {ok, Bytes} when Bytes =< Limit ->
            finish(allow, Policy, Operation, Subject, <<"allowed">>,
                   BudgetKind, Bytes, Limit);
        {ok, Bytes} ->
            Reason = case BudgetKind of
                arguments -> <<"argument_budget_exceeded">>;
                content -> <<"content_budget_exceeded">>
            end,
            finish(deny, Policy, Operation, Subject, Reason,
                   BudgetKind, Bytes, Limit);
        {error, invalid_value} ->
            Reason = case BudgetKind of
                arguments -> <<"invalid_arguments">>;
                content -> <<"invalid_content">>
            end,
            finish(deny, Policy, Operation, Subject, Reason,
                   BudgetKind, null, Limit)
    end.

finish(Outcome, Policy, Operation, Subject, Reason,
       BudgetKind, MeasuredBytes, Limit) ->
    OutcomeBinary = atom_to_binary(Outcome, utf8),
    Decision = decision(Policy, Operation, Subject, OutcomeBinary, Reason,
                        BudgetKind, MeasuredBytes, Limit),
    emit(Decision),
    {Outcome, Decision}.

authorize(none, _Subject, _Policy) -> allow;
authorize(RulesKey, Subject, Policy) ->
    Rules = maps:get(RulesKey, Policy),
    case selector_matches(maps:get(deny, Rules), Subject) of
        true -> {deny, <<"explicitly_denied">>};
        false ->
            case selector_matches(maps:get(allow, Rules), Subject) of
                true -> allow;
                false -> {deny, <<"not_allowed">>}
            end
    end.

measured_bytes(arguments, Value) -> json_bytes(Value);
measured_bytes(content, Value) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> {ok, byte_size(Value)};
        false -> {error, invalid_value}
    end;
measured_bytes(content, Value) -> json_bytes(Value).

json_bytes(Value) ->
    case adk_json:normalize(Value) of
        {ok, Canonical} ->
            try {ok, byte_size(jsx:encode(Canonical))}
            catch _:_ -> {error, invalid_value}
            end;
        {error, _} -> {error, invalid_value}
    end.

budget_limit(Policy, arguments) -> maps:get(max_argument_bytes, Policy);
budget_limit(Policy, content) -> maps:get(max_content_bytes, Policy).

%% Compilation

compile_rules(Rules, Kind) when is_map(Rules) ->
    case maps:without([allow, deny], Rules) of
        Unknown when map_size(Unknown) > 0 ->
            {error, {unsupported_runtime_policy_rules, Kind}};
        _ ->
            case {compile_selector(maps:get(allow, Rules, [])),
                  compile_selector(maps:get(deny, Rules, []))} of
                {{ok, Allow}, {ok, Deny}} ->
                    {ok, #{allow => Allow, deny => Deny}};
                {{error, _}, _} ->
                    {error, {invalid_runtime_policy_allow, Kind}};
                {_, {error, _}} ->
                    {error, {invalid_runtime_policy_deny, Kind}}
            end
    end;
compile_rules(_Rules, Kind) ->
    {error, {invalid_runtime_policy_rules, Kind}}.

compile_selector(all) -> {ok, all};
compile_selector(Names) when is_list(Names) ->
    case proper_name_list(Names, #{}) of
        {ok, Set} -> {ok, Set};
        error -> {error, invalid_selector}
    end;
compile_selector(_Names) -> {error, invalid_selector}.

proper_name_list([], Set) -> {ok, Set};
proper_name_list([Name | Rest], Set) ->
    case normalize_subject(Name) of
        {ok, Canonical} -> proper_name_list(Rest, Set#{Canonical => true});
        error -> error
    end;
proper_name_list(_Improper, _Set) -> error.

selector_matches(all, _Subject) -> true;
selector_matches(Set, Subject) -> maps:is_key(Subject, Set).

describe_rules(Rules) ->
    #{allow => describe_selector(maps:get(allow, Rules)),
      deny => describe_selector(maps:get(deny, Rules))}.

json_rules(Rules) ->
    #{<<"allow">> => json_selector(maps:get(allow, Rules)),
      <<"deny">> => json_selector(maps:get(deny, Rules))}.

describe_selector(all) -> all;
describe_selector(Set) -> lists:sort(maps:keys(Set)).

json_selector(all) -> <<"all">>;
json_selector(Set) -> lists:sort(maps:keys(Set)).

policy_id(undefined, Fingerprint) ->
    Prefix = binary:part(Fingerprint, 0, 16),
    {ok, <<"policy-", Prefix/binary>>};
policy_id(Value, _Fingerprint) ->
    case normalize_bounded_binary(Value, ?MAX_POLICY_ID_BYTES) of
        {ok, Id} -> {ok, Id};
        error -> {error, invalid_runtime_policy_id}
    end.

valid_limit(Value) -> is_integer(Value) andalso Value >= 0.

valid_policy(#{version := ?VERSION,
               id := Id, fingerprint := Fingerprint,
               agents := AgentRules, tools := ToolRules,
               max_argument_bytes := ArgumentLimit,
               max_content_bytes := ContentLimit}) ->
    is_binary(Id) andalso is_binary(Fingerprint) andalso
    is_map(AgentRules) andalso is_map(ToolRules) andalso
    valid_limit(ArgumentLimit) andalso valid_limit(ContentLimit);
valid_policy(_Policy) -> false.

normalize_subject(Value) -> normalize_bounded_binary(Value, ?MAX_NAME_BYTES).

normalize_bounded_binary(Value, MaxBytes)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< MaxBytes ->
    case valid_utf8(Value) of
        true -> {ok, Value};
        false -> error
    end;
normalize_bounded_binary(_Value, _MaxBytes) -> error.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) =:= Value
    catch _:_ -> false
    end.

%% Audit decisions and telemetry

decision(Policy, Operation, Subject, Outcome, Reason,
         BudgetKind, MeasuredBytes, Limit) ->
    Base = #{<<"schema_version">> => ?VERSION,
             <<"decision_id">> => decision_id(),
             <<"decided_at_ms">> => erlang:system_time(millisecond),
             <<"policy_id">> => maps:get(id, Policy),
             <<"policy_fingerprint">> => maps:get(fingerprint, Policy),
             <<"operation">> => Operation,
             <<"subject">> => Subject,
             <<"outcome">> => Outcome,
             <<"reason">> => Reason,
             <<"budget">> =>
                 #{<<"kind">> => atom_to_binary(BudgetKind, utf8),
                   <<"measured_bytes">> => MeasuredBytes,
                   <<"limit_bytes">> => Limit}},
    Base#{<<"decision_digest">> => fingerprint(Base)}.

fallback_decision(Operation, Subject0, BudgetKind, Reason) ->
    Subject = safe_subject(Subject0),
    Fingerprint = fingerprint(#{fallback => true}),
    Policy = #{id => <<"invalid-policy">>, fingerprint => Fingerprint},
    decision(Policy, Operation, Subject, <<"deny">>, Reason,
             BudgetKind, null, 0).

safe_subject(Value) ->
    case normalize_subject(Value) of
        {ok, Subject} -> Subject;
        error -> <<"<invalid>">>
    end.

decision_id() ->
    Integer = erlang:unique_integer([positive, monotonic]),
    <<"decision-", (integer_to_binary(Integer))/binary>>.

fingerprint(Value) ->
    Hash = crypto:hash(sha256, term_to_binary(Value, [deterministic])),
    binary:encode_hex(Hash, lowercase).

emit(Decision) ->
    case telemetry_started() of
        true ->
            Budget = maps:get(<<"budget">>, Decision),
            Measurements0 = #{limit_bytes =>
                                  maps:get(<<"limit_bytes">>, Budget)},
            Measurements = case maps:get(<<"measured_bytes">>, Budget) of
                Bytes when is_integer(Bytes) ->
                    Measurements0#{measured_bytes => Bytes};
                null -> Measurements0
            end,
            Metadata = #{policy_id => maps:get(<<"policy_id">>, Decision),
                         operation => maps:get(<<"operation">>, Decision),
                         outcome => maps:get(<<"outcome">>, Decision),
                         reason => maps:get(<<"reason">>, Decision)},
            try telemetry:execute([erlang_adk, policy, decision],
                                  Measurements, Metadata)
            catch _:_ -> ok
            end;
        false -> ok
    end,
    ok.

telemetry_started() ->
    lists:keymember(telemetry, 1, application:which_applications()).
