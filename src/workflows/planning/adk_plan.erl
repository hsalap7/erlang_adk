%% @doc Versioned, provider-neutral, JSON-safe planning contract.
%%
%% A plan is data only. Step actions are opaque JSON maps and are never
%% evaluated as Erlang code. A trusted `adk_plan_executor' adapter decides how
%% to interpret an action at execution time.
-module(adk_plan).

-export([schema_version/0,
         new/4, new/5,
         step/3, step/4,
         validate/1, encode/1, decode/1,
         steps/1]).

-define(VERSION, 1).

%% Erlang map type syntax cannot express literal binary keys. Runtime
%% validation below owns the exact canonical shape.
-type step() :: map().
-type plan() :: map().
-export_type([plan/0, step/0]).

-spec schema_version() -> pos_integer().
schema_version() -> ?VERSION.

-spec new(binary(), non_neg_integer(), term(), [map()]) ->
    {ok, plan()} | {error, term()}.
new(Id, Revision, Goal, Steps) ->
    new(Id, Revision, Goal, Steps, #{}).

-spec new(binary(), non_neg_integer(), term(), [map()], map()) ->
    {ok, plan()} | {error, term()}.
new(Id, Revision, Goal, Steps, Metadata) ->
    validate(#{id => Id, revision => Revision, goal => Goal,
               steps => Steps, metadata => Metadata}).

-spec step(binary(), binary(), map()) ->
    {ok, step()} | {error, term()}.
step(Id, Description, Action) ->
    step(Id, Description, Action, #{}).

-spec step(binary(), binary(), map(), map()) ->
    {ok, step()} | {error, term()}.
step(Id, Description, Action, Metadata) ->
    validate_step(#{id => Id, description => Description,
                    action => Action, metadata => Metadata}, 0).

-spec validate(map()) -> {ok, plan()} | {error, term()}.
validate(Plan) when is_map(Plan) ->
    case unknown_keys(Plan, plan_keys()) of
        [] -> validate_plan_fields(Plan);
        Unknown -> {error, {unknown_plan_fields, Unknown}}
    end;
validate(_) ->
    {error, invalid_plan}.

-spec encode(plan()) -> {ok, plan()} | {error, term()}.
encode(Plan) -> validate(Plan).

-spec decode(map()) -> {ok, plan()} | {error, term()}.
decode(Plan) -> validate(Plan).

-spec steps(plan()) -> [step()].
steps(#{<<"schema_version">> := ?VERSION, <<"steps">> := Steps}) ->
    Steps.

validate_plan_fields(Plan) ->
    case {field(Plan, schema_version, ?VERSION),
          required_field(Plan, id),
          required_field(Plan, revision),
          required_field(Plan, goal),
          required_field(Plan, steps),
          field(Plan, metadata, #{})} of
        {{ok, ?VERSION}, {ok, Id}, {ok, Revision}, {ok, Goal0},
         {ok, Steps0}, {ok, Metadata0}}
          when is_binary(Id), byte_size(Id) > 0,
               is_integer(Revision), Revision >= 0,
               is_list(Steps0), Steps0 =/= [], is_map(Metadata0) ->
            case {valid_utf8(Id), safe_value(Goal0),
                  validate_steps(Steps0, 0, [], #{}),
                  safe_map(Metadata0)} of
                {true, {ok, Goal}, {ok, Steps}, {ok, Metadata}} ->
                    {ok, #{<<"schema_version">> => ?VERSION,
                           <<"id">> => Id,
                           <<"revision">> => Revision,
                           <<"goal">> => Goal,
                           <<"steps">> => Steps,
                           <<"metadata">> => Metadata}};
                {false, _, _, _} -> {error, invalid_plan_id};
                {_, {error, _} = Error, _, _} -> Error;
                {_, _, {error, _} = Error, _} -> Error;
                {_, _, _, {error, _} = Error} -> Error
            end;
        {{ok, Version}, _, _, _, _, _} when Version =/= ?VERSION ->
            {error, {unsupported_plan_schema_version, Version}};
        {{error, _} = Error, _, _, _, _, _} -> Error;
        {_, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _, _} -> Error;
        {_, _, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_plan_fields}
    end.

validate_steps([], _Index, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
validate_steps([Step0 | Rest], Index, Acc, Ids) when is_map(Step0) ->
    case validate_step(Step0, Index) of
        {ok, Step} ->
            Id = maps:get(<<"id">>, Step),
            case maps:is_key(Id, Ids) of
                true -> {error, {duplicate_plan_step_id, Id}};
                false ->
                    validate_steps(Rest, Index + 1, [Step | Acc],
                                   Ids#{Id => true})
            end;
        {error, _} = Error -> Error
    end;
validate_steps([_ | _], Index, _Acc, _Ids) ->
    {error, {invalid_plan_step, Index}};
validate_steps(_Improper, Index, _Acc, _Ids) ->
    {error, {invalid_plan_step_list, Index}}.

validate_step(Step, Index) when is_map(Step) ->
    case unknown_keys(Step, step_keys()) of
        [] ->
            case {required_field(Step, id),
                  required_field(Step, description),
                  required_field(Step, action),
                  field(Step, metadata, #{})} of
                {{ok, Id}, {ok, Description}, {ok, Action0},
                 {ok, Metadata0}}
                  when is_binary(Id), byte_size(Id) > 0,
                       is_binary(Description), byte_size(Description) > 0,
                       is_map(Action0), is_map(Metadata0) ->
                    case {valid_utf8(Id), valid_utf8(Description),
                          safe_map(Action0), safe_map(Metadata0)} of
                        {true, true, {ok, Action}, {ok, Metadata}} ->
                            {ok, #{<<"id">> => Id,
                                   <<"description">> => Description,
                                   <<"action">> => Action,
                                   <<"metadata">> => Metadata}};
                        _ -> {error, {invalid_plan_step, Index}}
                    end;
                _ -> {error, {invalid_plan_step, Index}}
            end;
        Unknown -> {error, {unknown_plan_step_fields, Index, Unknown}}
    end.

required_field(Map, Key) ->
    case alias_values(Map, Key) of
        [] -> {error, {missing_plan_field, Key}};
        [Value] -> {ok, Value};
        [_ | _] -> {error, {duplicate_plan_field, Key}}
    end.

field(Map, Key, Default) ->
    case alias_values(Map, Key) of
        [] -> {ok, Default};
        [Value] -> {ok, Value};
        [_ | _] -> {error, {duplicate_plan_field, Key}}
    end.

alias_values(Map, Key) ->
    BinaryKey = atom_to_binary(Key, utf8),
    [Value || Alias <- [Key, BinaryKey],
              {ok, Value} <- [maps:find(Alias, Map)]].

unknown_keys(Map, Allowed) ->
    lists:sort(maps:keys(maps:without(Allowed, Map))).

plan_keys() ->
    aliases([schema_version, id, revision, goal, steps, metadata]).

step_keys() ->
    aliases([id, description, action, metadata]).

aliases(Keys) ->
    lists:append([[Key, atom_to_binary(Key, utf8)] || Key <- Keys]).

safe_map(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        _ -> {error, invalid_plan_json}
    end.

safe_value(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} -> {ok, Safe};
        _ -> {error, invalid_plan_json}
    end.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.
