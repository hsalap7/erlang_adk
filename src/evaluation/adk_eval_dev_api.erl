%% @doc Safe Developer UI facade for durable evaluation authoring/history.
%%
%% Browser input can select only an already-registered agent and first-party
%% metric IDs. Adapter/metric modules, store handles, nodes, and credentials
%% are fixed by this module and can never be supplied in JSON.
-module(adk_eval_dev_api).

-export([submit/3, list_jobs/3, status/3, result/3, report/5, cancel/3,
         list_sets/3, get_set/4, put_baseline/4, get_baseline/3]).

-define(MAX_METRICS, 16).

-spec submit(gen_server:server_ref(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
submit(Service, Scope, Payload) when is_map(Payload) ->
    Allowed = [<<"agent_name">>, <<"set">>, <<"metrics">>,
               <<"options">>, <<"metadata">>],
    AgentName = maps:get(<<"agent_name">>, Payload, undefined),
    Set0 = maps:get(<<"set">>, Payload, undefined),
    Metrics0 = maps:get(<<"metrics">>, Payload, undefined),
    Options = maps:get(<<"options">>, Payload, #{}),
    Metadata = maps:get(<<"metadata">>, Payload, #{}),
    case {maps:keys(maps:without(Allowed, Payload)),
          adk_agent_tree:validate_name(AgentName),
          is_map(Set0), is_map(Options), is_map(Metadata),
          normalize_metrics(Metrics0)} of
        {[], {ok, AgentName}, true, true, true, {ok, Metrics}} ->
            case {adk_agent_registry:lookup(AgentName),
                  adk_eval_set:decode(Set0)} of
                {{ok, AgentPid}, {ok, Set}} when is_pid(AgentPid) ->
                    Request = #{
                      set => Set,
                      adapter =>
                          #{module => adk_eval_agent_adapter,
                            target => #{agent_name => AgentName,
                                        runner_options => #{}},
                            config => #{}},
                      metrics => Metrics,
                      options => Options,
                      metadata => Metadata},
                    adk_eval_service:submit(Service, Scope, Request);
                {{error, _}, _} -> {error, agent_not_found};
                {_, {error, _}} -> {error, invalid_eval_set}
            end;
        {[_ | _], _, _, _, _, _} -> {error, unknown_eval_authoring_fields};
        {_, {error, _}, _, _, _, _} -> {error, invalid_agent_name};
        {_, _, false, _, _, _} -> {error, invalid_eval_set};
        {_, _, _, false, _, _} -> {error, invalid_eval_options};
        {_, _, _, _, false, _} -> {error, invalid_eval_metadata};
        {_, _, _, _, _, {error, _} = Error} -> Error
    end;
submit(_Service, _Scope, _Payload) -> {error, invalid_eval_authoring_request}.

list_jobs(Service, Scope, Options) when is_map(Options) ->
    adk_eval_service:list_jobs(Service, Scope, Options).

status(Service, Scope, JobId) ->
    adk_eval_service:status(Service, Scope, JobId).

result(Service, Scope, JobId) ->
    adk_eval_service:result(Service, Scope, JobId).

%% @doc Fetch and render the canonical result persisted for one completed job.
%% This is the only stored-result formatting surface used by the Developer HTTP
%% API; CLI report retrieval consumes the same response bytes.
-spec report(gen_server:server_ref(), adk_eval_store:scope(), binary(),
             binary(), map()) -> {ok, binary()} | {error, term()}.
report(Service, Scope, JobId, Format, Options) ->
    case result(Service, Scope, JobId) of
        {ok, Result} -> adk_eval_dev_view:render(Result, Format, Options);
        {error, _} = Error -> Error
    end.

cancel(Service, Scope, JobId) ->
    adk_eval_service:cancel(Service, Scope, JobId).

list_sets(Service, Scope, Options) when is_map(Options) ->
    adk_eval_service:list_sets(Service, Scope, Options).

get_set(Service, Scope, Id, Version) ->
    adk_eval_service:get_set(Service, Scope, Id, Version).

put_baseline(Service, Scope, Name, JobId) ->
    adk_eval_service:put_baseline(Service, Scope, Name, JobId).

get_baseline(Service, Scope, Name) ->
    adk_eval_service:get_baseline(Service, Scope, Name).

normalize_metrics(Metrics) when is_list(Metrics) ->
    normalize_metrics(Metrics, 0, #{}, []);
normalize_metrics(_) -> {error, invalid_eval_metrics}.

normalize_metrics([], 0, _Ids, _Acc) -> {error, empty_eval_metrics};
normalize_metrics([], _Count, _Ids, Acc) -> {ok, lists:reverse(Acc)};
normalize_metrics([Metric | Rest], Count, Ids, Acc)
  when is_map(Metric), Count < ?MAX_METRICS ->
    Allowed = [<<"id">>, <<"metric">>, <<"threshold">>,
               <<"scope">>, <<"config">>],
    Id = maps:get(<<"id">>, Metric, undefined),
    Kind = maps:get(<<"metric">>, Metric, undefined),
    Threshold = maps:get(<<"threshold">>, Metric, 1.0),
    Scope0 = maps:get(<<"scope">>, Metric, <<"case">>),
    Config0 = maps:get(<<"config">>, Metric, #{}),
    case {maps:keys(maps:without(Allowed, Metric)), valid_id(Id),
          maps:is_key(Id, Ids), valid_metric(Kind), valid_score(Threshold),
          metric_scope(Scope0), is_map(Config0)} of
        {[], true, false, true, true, {ok, Scope}, true} ->
            Config = normalize_metric_config(
                       Kind, Config0#{<<"metric">> => Kind}),
            case adk_eval_builtin_metric:validate_config(Config) of
                ok ->
                    Descriptor = #{id => Id,
                                   module => adk_eval_builtin_metric,
                                   kind => metric, scope => Scope,
                                   threshold => Threshold, config => Config},
                    normalize_metrics(Rest, Count + 1, Ids#{Id => true},
                                      [Descriptor | Acc]);
                {error, _} -> {error, invalid_eval_metric_config}
            end;
        {[_ | _], _, _, _, _, _, _} ->
            {error, unknown_eval_metric_fields};
        {_, _, true, _, _, _, _} -> {error, duplicate_eval_metric_id};
        _ -> {error, invalid_eval_metric}
    end;
normalize_metrics([_ | _], Count, _Ids, _Acc)
  when Count >= ?MAX_METRICS -> {error, eval_metric_limit_exceeded};
normalize_metrics(_Improper, _Count, _Ids, _Acc) ->
    {error, invalid_eval_metrics}.

valid_metric(<<"latency">>) -> true;
valid_metric(<<"cost">>) -> true;
valid_metric(<<"safety">>) -> true;
valid_metric(<<"semantic_quality">>) -> true;
valid_metric(_) -> false.

normalize_metric_config(<<"semantic_quality">>, Config) ->
    case maps:get(<<"algorithm">>, Config, undefined) of
        <<"exact_normalized">> ->
            (maps:remove(<<"algorithm">>, Config))#{
              algorithm => exact_normalized};
        <<"token_f1">> ->
            (maps:remove(<<"algorithm">>, Config))#{algorithm => token_f1};
        _ -> Config
    end;
normalize_metric_config(_Metric, Config) -> Config.

metric_scope(<<"turn">>) -> {ok, turn};
metric_scope(<<"case">>) -> {ok, 'case'};
metric_scope(_) -> error.

valid_score(Value) -> is_number(Value) andalso Value >= 0 andalso Value =< 1.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                     byte_size(Value) =< 256 ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_id(_) -> false.
