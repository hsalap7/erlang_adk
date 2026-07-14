%% @doc Validated immutable configuration for LLM-agent request preparation.
%%
%% This module deliberately owns no process and performs no persistence. A
%% runner compiles a spec once, calls prepare/4 before a model request, and
%% calls finalize/2 for a final model value. The returned state delta is meant
%% to be attached to the same final event that stores the response, preserving
%% the session service's existing atomic event/state commit.
-module(adk_agent_spec).

-export([compile/1, compile/2, from_config/1, from_config/2,
         prepare/4, finalize/2, validate_input/2, validate_output/2,
         check_capabilities/2, required_capabilities/1]).

-record(spec, {
    instruction :: adk_agent_instruction:instruction(),
    global_instruction :: adk_agent_instruction:instruction(),
    input_schema = undefined :: adk_json_schema:schema(),
    output_schema = undefined :: adk_json_schema:schema(),
    generation_config = #{} :: map(),
    history_policy = include :: include | exclude,
    output_key = undefined :: undefined | binary(),
    required_capabilities = [] :: [atom()],
    instruction_timeout_ms = 5000 :: pos_integer(),
    artifact_timeout_ms = 2000 :: pos_integer(),
    max_instruction_bytes = 65536 :: pos_integer()
}).

-opaque spec() :: #spec{}.
-type error_reason() :: invalid_agent_spec |
                        unsupported_agent_spec_options |
                        invalid_history_policy |
                        invalid_output_key |
                        invalid_generation_config |
                        {invalid_generation_option, atom()} |
                        invalid_required_capabilities |
                        invalid_capabilities |
                        {missing_capabilities, [atom()]} |
                        invalid_history |
                        {input_schema_failed, term()} |
                        {output_schema_failed, term()} |
                        adk_agent_instruction:error_reason() |
                        adk_json_schema:error_reason().

-export_type([spec/0, error_reason/0]).

-define(DEFAULT_INSTRUCTION, <<"You are a helpful assistant.">>).

%% @doc Strictly compile a map containing only agent-spec options.
-spec compile(map()) -> {ok, spec()} | {error, error_reason()}.
compile(Options) ->
    compile_options(Options).

%% @doc Compile and immediately check provider capability discovery output.
-spec compile(map(), map()) -> {ok, spec()} | {error, error_reason()}.
compile(Options, Capabilities) ->
    case compile_options(Options) of
        {ok, Spec} ->
            case check_capabilities(Spec, Capabilities) of
                ok -> {ok, Spec};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%% @doc Narrow integration entry for the existing LLM config map. Only agent
%% contract keys are copied; provider credentials and transport options are
%% intentionally not retained in the immutable spec.
-spec from_config(map()) -> {ok, spec()} | {error, error_reason()}.
from_config(Config) when is_map(Config) ->
    compile(extract_options(Config));
from_config(_Config) ->
    {error, invalid_agent_spec}.

-spec from_config(map(), map()) -> {ok, spec()} | {error, error_reason()}.
from_config(Config, Capabilities) when is_map(Config), is_map(Capabilities) ->
    compile(extract_options(Config), Capabilities);
from_config(_Config, _Capabilities) ->
    {error, invalid_agent_spec}.

compile_options(Options) when is_map(Options) ->
    case maps:without(option_keys(), Options) of
        Unknown when map_size(Unknown) > 0 ->
            {error, unsupported_agent_spec_options};
        _ ->
            compile_known_options(Options)
    end;
compile_options(_Options) ->
    {error, invalid_agent_spec}.

compile_known_options(Options) ->
    InstructionTimeout = maps:get(instruction_timeout_ms, Options, 5000),
    ArtifactTimeout = maps:get(artifact_timeout_ms, Options, 2000),
    MaxInstructionBytes = maps:get(max_instruction_bytes, Options, 65536),
    case valid_positive(InstructionTimeout) andalso
         valid_positive(ArtifactTimeout) andalso
         valid_positive(MaxInstructionBytes) of
        false ->
            {error, invalid_agent_spec};
        true ->
            Instruction0 = maps:get(instructions, Options,
                                    ?DEFAULT_INSTRUCTION),
            GlobalInstruction0 = maps:get(global_instruction, Options, <<>>),
            compile_parts(Options, Instruction0, GlobalInstruction0,
                          InstructionTimeout,
                          ArtifactTimeout, MaxInstructionBytes)
    end.

compile_parts(Options, Instruction0, GlobalInstruction0, InstructionTimeout,
              ArtifactTimeout, MaxInstructionBytes) ->
    case adk_agent_instruction:compile(Instruction0, MaxInstructionBytes) of
        {ok, Instruction} ->
            case adk_agent_instruction:compile(
                   GlobalInstruction0, MaxInstructionBytes) of
                {ok, GlobalInstruction} ->
                    compile_contract_parts(
                      Options, Instruction, GlobalInstruction,
                      InstructionTimeout, ArtifactTimeout,
                      MaxInstructionBytes);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

compile_contract_parts(Options, Instruction, GlobalInstruction,
                       InstructionTimeout, ArtifactTimeout,
                       MaxInstructionBytes) ->
    case compile_schemas(Options) of
        {ok, InputSchema, OutputSchema} ->
            case generation_config(Options) of
                {ok, GenerationConfig} ->
                    finish_compile(Options, Instruction,
                                   GlobalInstruction,
                                   InputSchema, OutputSchema,
                                   GenerationConfig,
                                   InstructionTimeout,
                                   ArtifactTimeout,
                                   MaxInstructionBytes);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

compile_schemas(Options) ->
    case adk_json_schema:compile(maps:get(input_schema, Options, undefined)) of
        {ok, InputSchema} ->
            case adk_json_schema:compile(
                   maps:get(output_schema, Options, undefined)) of
                {ok, OutputSchema} -> {ok, InputSchema, OutputSchema};
                {error, Reason} -> {error, {output_schema_failed, Reason}}
            end;
        {error, Reason} -> {error, {input_schema_failed, Reason}}
    end.

finish_compile(Options, Instruction, GlobalInstruction,
               InputSchema, OutputSchema,
               GenerationConfig, InstructionTimeout, ArtifactTimeout,
               MaxInstructionBytes) ->
    case history_policy(Options) of
        {ok, HistoryPolicy} ->
            case output_key(maps:get(output_key, Options, undefined)) of
                {ok, OutputKey} ->
                    case explicit_capabilities(Options) of
                        {ok, ExplicitCapabilities} ->
                            Required = derive_capabilities(
                                         GenerationConfig, OutputSchema,
                                         ExplicitCapabilities),
                            {ok, #spec{
                              instruction = Instruction,
                              global_instruction = GlobalInstruction,
                              input_schema = InputSchema,
                              output_schema = OutputSchema,
                              generation_config = GenerationConfig,
                              history_policy = HistoryPolicy,
                              output_key = OutputKey,
                              required_capabilities = Required,
                              instruction_timeout_ms = InstructionTimeout,
                              artifact_timeout_ms = ArtifactTimeout,
                              max_instruction_bytes = MaxInstructionBytes}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%% @doc Validate input, resolve instructions, and apply the immutable history
%% policy. The returned map is provider-neutral.
-spec prepare(spec(), term(), list(), map()) ->
    {ok, map()} | {error, error_reason()}.
prepare(Spec = #spec{}, Input, History, Context) when is_list(History),
                                                     is_map(Context) ->
    case validate_input(Spec, Input) of
        {ok, CanonicalInput} ->
            InstructionOptions = #{
                timeout_ms => Spec#spec.instruction_timeout_ms,
                artifact_timeout_ms => Spec#spec.artifact_timeout_ms,
                max_bytes => Spec#spec.max_instruction_bytes
            },
            case adk_agent_instruction:resolve(
                   Spec#spec.instruction, Context, InstructionOptions) of
                {ok, Instructions} ->
                    case adk_agent_instruction:resolve(
                           Spec#spec.global_instruction, Context,
                           InstructionOptions) of
                        {ok, GlobalInstruction} ->
                            FilteredHistory = case Spec#spec.history_policy of
                                include -> History;
                                exclude -> []
                            end,
                            {ok, #{input => CanonicalInput,
                                   instructions => Instructions,
                                   global_instruction => GlobalInstruction,
                                   history => FilteredHistory,
                                   history_policy => Spec#spec.history_policy,
                                   generation_config =>
                                       Spec#spec.generation_config,
                                   output_schema => Spec#spec.output_schema}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
prepare(#spec{}, _Input, History, _Context) when not is_list(History) ->
    {error, invalid_history};
prepare(#spec{}, _Input, _History, _Context) ->
    {error, invalid_instruction_context};
prepare(_Spec, _Input, _History, _Context) ->
    {error, invalid_agent_spec}.

%% @doc Validate a final model value and produce an atomic state delta. No
%% delta is returned when schema validation fails.
-spec finalize(spec(), term()) ->
    {ok, term(), map()} | {error, error_reason()}.
finalize(Spec = #spec{}, Output) ->
    case validate_output(Spec, Output) of
        {ok, CanonicalOutput} ->
            Delta = case Spec#spec.output_key of
                undefined -> #{};
                Key -> #{Key => CanonicalOutput}
            end,
            {ok, CanonicalOutput, Delta};
        {error, _} = Error -> Error
    end;
finalize(_Spec, _Output) ->
    {error, invalid_agent_spec}.

-spec validate_input(spec(), term()) ->
    {ok, term()} | {error, error_reason()}.
validate_input(#spec{input_schema = Schema}, Input) ->
    validate_contract(input_schema_failed, Schema, Input);
validate_input(_Spec, _Input) ->
    {error, invalid_agent_spec}.

-spec validate_output(spec(), term()) ->
    {ok, term()} | {error, error_reason()}.
validate_output(#spec{output_schema = Schema}, Output) ->
    validate_contract(output_schema_failed, Schema, Output);
validate_output(_Spec, _Output) ->
    {error, invalid_agent_spec}.

validate_contract(Label, undefined, Value) ->
    case adk_json_schema:validate(undefined, Value) of
        {ok, Canonical} -> {ok, Canonical};
        {error, Reason} -> {error, {Label, Reason}}
    end;
validate_contract(Label, Schema, Value) when is_binary(Value) ->
    case decode_json(Value) of
        {ok, Decoded} -> validate_schema_value(Label, Schema, Decoded);
        error -> validate_schema_value(Label, Schema, Value)
    end;
validate_contract(Label, Schema, Value) ->
    validate_schema_value(Label, Schema, Value).

validate_schema_value(Label, Schema, Value) ->
    case adk_json_schema:validate(Schema, Value) of
        {ok, Canonical} -> {ok, Canonical};
        {error, Reason} -> {error, {Label, Reason}}
    end.

decode_json(Binary) ->
    try jsx:decode(Binary, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> error
    end.

%% @doc Verify every explicit/derived feature against provider discovery.
-spec check_capabilities(spec(), map()) ->
    ok | {error, error_reason()}.
check_capabilities(#spec{required_capabilities = Required}, Capabilities)
  when is_map(Capabilities) ->
    Missing = [Capability || Capability <- Required,
                             maps:get(Capability, Capabilities, false) =/= true],
    case Missing of
        [] -> ok;
        _ -> {error, {missing_capabilities, Missing}}
    end;
check_capabilities(#spec{}, _Capabilities) ->
    {error, invalid_capabilities};
check_capabilities(_Spec, _Capabilities) ->
    {error, invalid_agent_spec}.

-spec required_capabilities(spec()) -> [atom()].
required_capabilities(#spec{required_capabilities = Required}) -> Required.

derive_capabilities(GenerationConfig, OutputSchema, Explicit) ->
    WithGeneration = case map_size(GenerationConfig) > 0 of
        true -> [generation_config | Explicit];
        false -> Explicit
    end,
    WithThinking = case maps:is_key(thinking_config, GenerationConfig) of
        true -> [thinking | WithGeneration];
        false -> WithGeneration
    end,
    WithSafety = case maps:is_key(safety_settings, GenerationConfig) of
        true -> [safety_settings | WithThinking];
        false -> WithThinking
    end,
    WithStructured = case OutputSchema of
        undefined -> WithSafety;
        _ -> [structured_output | WithSafety]
    end,
    lists:usort(WithStructured).

explicit_capabilities(Options) ->
    case maps:get(required_capabilities, Options, []) of
        Required when is_list(Required) ->
            case lists:all(fun(Capability) ->
                               is_atom(Capability) andalso
                               Capability =/= undefined
                           end, Required) of
                true -> {ok, lists:usort(Required)};
                false -> {error, invalid_required_capabilities}
            end;
        _ -> {error, invalid_required_capabilities}
    end.

history_policy(Options) ->
    PolicyValue = maps:get(history_policy, Options, absent),
    IncludeValue = maps:get(include_history, Options, absent),
    IncludeContents = maps:get(include_contents, Options, absent),
    Values = [Value || Value <- [PolicyValue, IncludeValue, IncludeContents],
                       Value =/= absent],
    case Values of
        [] -> {ok, include};
        [Value] -> normalize_history_policy(Value);
        _ -> {error, invalid_history_policy}
    end.

normalize_history_policy(include) -> {ok, include};
normalize_history_policy(exclude) -> {ok, exclude};
normalize_history_policy(default) -> {ok, include};
normalize_history_policy(none) -> {ok, exclude};
normalize_history_policy(true) -> {ok, include};
normalize_history_policy(false) -> {ok, exclude};
normalize_history_policy(_) -> {error, invalid_history_policy}.

output_key(undefined) -> {ok, undefined};
output_key(Key0) ->
    case nonempty_binary(Key0) of
        {ok, Key} ->
            case valid_state_key(Key) andalso
                 not adk_agent_instruction:is_secret_key(Key) of
                true -> {ok, Key};
                false -> {error, invalid_output_key}
            end;
        error -> {error, invalid_output_key}
    end.

valid_state_key(Key) ->
    re:run(Key,
           <<"^(?:(?:app|user|temp):)?[A-Za-z_][A-Za-z0-9_.-]*$">>,
           [{capture, none}]) =:= match.

generation_config(Options) ->
    case maps:get(generation_config, Options, #{}) of
        Config when is_map(Config) -> normalize_generation_config(Config);
        _ -> {error, invalid_generation_config}
    end.

normalize_generation_config(Config0) ->
    case normalize_max_tokens_alias(Config0) of
        {ok, Config} ->
            Allowed = generation_keys(),
            case maps:without(Allowed, Config) of
                Unknown when map_size(Unknown) > 0 ->
                    {error, invalid_generation_config};
                _ -> validate_generation_pairs(Allowed, Config, #{})
            end;
        {error, _} = Error -> Error
    end.

normalize_max_tokens_alias(Config) ->
    case {maps:find(max_output_tokens, Config), maps:find(max_tokens, Config)} of
        {error, _} -> {ok, Config};
        {{ok, Value}, error} ->
            {ok, maps:put(max_tokens, Value,
                          maps:remove(max_output_tokens, Config))};
        {{ok, _}, {ok, _}} -> {error, invalid_generation_config}
    end.

validate_generation_pairs([], _Config, Acc) -> {ok, Acc};
validate_generation_pairs([Key | Rest], Config, Acc) ->
    case maps:find(Key, Config) of
        error -> validate_generation_pairs(Rest, Config, Acc);
        {ok, Value} ->
            case valid_generation_value(Key, Value) of
                true -> validate_generation_pairs(Rest, Config,
                                                  Acc#{Key => Value});
                false -> {error, {invalid_generation_option, Key}}
            end
    end.

valid_generation_value(temperature, Value) -> in_range(Value, 0, 2);
valid_generation_value(top_p, Value) -> in_range(Value, 0, 1);
valid_generation_value(top_k, Value) ->
    is_integer(Value) andalso Value >= 0;
valid_generation_value(max_tokens, Value) ->
    is_integer(Value) andalso Value > 0;
valid_generation_value(candidate_count, Value) ->
    is_integer(Value) andalso Value > 0;
valid_generation_value(seed, Value) ->
    is_integer(Value) andalso Value >= 0;
valid_generation_value(presence_penalty, Value) -> in_range(Value, -2, 2);
valid_generation_value(frequency_penalty, Value) -> in_range(Value, -2, 2);
valid_generation_value(stop_sequences, Values) when is_list(Values) ->
    Values =/= [] andalso length(Values) =< 16 andalso
    length(Values) =:= length(lists:usort(Values)) andalso
    lists:all(fun(Value) ->
                  is_binary(Value) andalso byte_size(Value) > 0 andalso
                  byte_size(Value) =< 1024
              end, Values);
valid_generation_value(response_mime_type, Value) ->
    is_binary(Value) andalso byte_size(Value) > 0;
valid_generation_value(thinking_config, Value) ->
    valid_thinking_config(Value);
valid_generation_value(safety_settings, Value) ->
    element(1, adk_gemini_safety:normalize(Value)) =:= ok;
valid_generation_value(_Key, _Value) -> false.

valid_thinking_config(Config) when is_map(Config), map_size(Config) > 0 ->
    Allowed = [thinking_level, thinking_budget, include_thoughts],
    Unknown = maps:without(Allowed, Config),
    Level = maps:get(thinking_level, Config, undefined),
    Budget = maps:get(thinking_budget, Config, undefined),
    Include = maps:get(include_thoughts, Config, undefined),
    map_size(Unknown) =:= 0 andalso
    not (Level =/= undefined andalso Budget =/= undefined) andalso
    valid_optional_thinking_level(Level) andalso
    valid_optional_thinking_budget(Budget) andalso
    valid_optional_boolean(Include);
valid_thinking_config(_Config) ->
    false.

valid_optional_thinking_level(undefined) -> true;
valid_optional_thinking_level(minimal) -> true;
valid_optional_thinking_level(low) -> true;
valid_optional_thinking_level(medium) -> true;
valid_optional_thinking_level(high) -> true;
valid_optional_thinking_level(<<"minimal">>) -> true;
valid_optional_thinking_level(<<"low">>) -> true;
valid_optional_thinking_level(<<"medium">>) -> true;
valid_optional_thinking_level(<<"high">>) -> true;
valid_optional_thinking_level(_) -> false.

valid_optional_thinking_budget(undefined) -> true;
valid_optional_thinking_budget(-1) -> true;
valid_optional_thinking_budget(Value) ->
    is_integer(Value) andalso Value >= 0.

valid_optional_boolean(undefined) -> true;
valid_optional_boolean(Value) -> is_boolean(Value).

in_range(Value, Minimum, Maximum) when is_integer(Value); is_float(Value) ->
    Value >= Minimum andalso Value =< Maximum;
in_range(_Value, _Minimum, _Maximum) -> false.

extract_options(Config) ->
    Base = maps:with(option_keys(), Config),
    TopLevelGeneration = maps:with(
                           generation_keys() ++ [max_output_tokens], Config),
    NestedGeneration = maps:get(generation_config, Base, #{}),
    Generation = case is_map(NestedGeneration) of
        true -> maps:merge(TopLevelGeneration, NestedGeneration);
        false -> NestedGeneration
    end,
    WithGeneration = case Generation of
        #{} when map_size(Generation) =:= 0 ->
            maps:remove(generation_config, Base);
        _ -> Base#{generation_config => Generation}
    end,
    case {maps:is_key(output_schema, WithGeneration),
          maps:find(response_schema, Config)} of
        {false, {ok, Schema}} -> WithGeneration#{output_schema => Schema};
        _ -> WithGeneration
    end.

option_keys() ->
    [instructions, global_instruction, input_schema, output_schema,
     generation_config,
     history_policy, include_history, include_contents, output_key,
     required_capabilities, instruction_timeout_ms, artifact_timeout_ms,
     max_instruction_bytes].

generation_keys() ->
    [temperature, top_p, top_k, max_tokens, candidate_count, seed,
     presence_penalty, frequency_penalty, stop_sequences,
     response_mime_type, thinking_config, safety_settings].

nonempty_binary(Value) when is_binary(Value), byte_size(Value) > 0 ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> error
    end;
nonempty_binary(Value) when is_list(Value), Value =/= [] ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary), byte_size(Binary) > 0 -> {ok, Binary};
        _ -> error
    catch
        _:_ -> error
    end;
nonempty_binary(_Value) -> error.

valid_positive(Value) -> is_integer(Value) andalso Value > 0.
