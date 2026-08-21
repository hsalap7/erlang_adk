%% @doc Deterministic, bounded evaluation-report rendering and CI exporters.
%%
%% Exporters intentionally include identifiers, aggregate scores, and failure
%% states only. Prompts, model responses, tool arguments, and adapter metadata
%% are never copied into JUnit, SARIF, or annotation output.
-module(adk_eval_export).

-include("adk_eval_report.hrl").

-export([render/3, junit/2, sarif/2, annotations/2]).

-type format() :: json | markdown | junit | sarif | annotations.
-export_type([format/0]).

-define(MAX_ANNOTATIONS, 10000).

%% @doc Render one checked result (or, for JSON/Markdown, one canonical
%% baseline comparison) through the shared CLI/API formatting boundary.
%%
%% `max_bytes' is applied to every format, including annotation JSON.  Keeping
%% this dispatch here prevents the command line and Developer API from
%% acquiring subtly different encoding, escaping, or size-limit behavior.
-spec render(map(), format(), map()) ->
    {ok, binary()} | {error, term()}.
render(Value, Format, Options0) when is_map(Options0) ->
    case normalize_options(Options0) of
        {error, _} = Error -> Error;
        {ok, Options} -> render_checked(Value, Format, Options)
    end;
render(_Value, _Format, _Options) ->
    {error, invalid_eval_export_options}.

render_checked(Value, Format, Options)
  when Format =:= json; Format =:= markdown ->
    case adk_eval_set:report(Value, Format) of
        {ok, Output} -> bounded_binary(Output, Options);
        {error, _} = Error -> Error
    end;
render_checked(Value, junit, Options) ->
    junit(Value, Options);
render_checked(Value, sarif, Options) ->
    sarif(Value, Options);
render_checked(Value, annotations, Options) ->
    case annotations(Value, Options) of
        {ok, Values} ->
            try jsx:encode(Values) of
                Output -> bounded_binary(Output, Options)
            catch
                _:_ -> {error, invalid_eval_annotations}
            end;
        {error, _} = Error -> Error
    end;
render_checked(_Value, _Format, _Options) ->
    {error, invalid_eval_report_format}.

-spec junit(map(), map()) -> {ok, binary()} | {error, term()}.
junit(Result0, Options) ->
    with_result(Result0, Options,
      fun(Result, Opts) ->
          Suite = maps:get(suite_name, Opts),
          Cases = maps:get(<<"cases">>, Result),
          Failures = length([ok || Case <- Cases,
                                  not maps:get(<<"passed">>, Case, false)]),
          Duration = maps:get(<<"duration_ms">>, Result, 0) / 1000,
          Header = [<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n">>,
                    <<"<testsuite name=\"">>, xml(Suite),
                    <<"\" tests=\"">>, integer_to_binary(length(Cases)),
                    <<"\" failures=\"">>, integer_to_binary(Failures),
                    <<"\" time=\"">>, decimal(Duration), <<"\">\n">>],
          Body = [junit_case(Case) || Case <- Cases],
          Footer = <<"</testsuite>\n">>,
          bounded_binary([Header, Body, Footer], Opts)
      end).

-spec sarif(map(), map()) -> {ok, binary()} | {error, term()}.
sarif(Result0, Options) ->
    with_result(Result0, Options,
      fun(Result, Opts) ->
          Rules = [#{<<"id">> => maps:get(<<"metric_id">>, Metric),
                     <<"name">> => maps:get(<<"metric_id">>, Metric),
                     <<"shortDescription">> =>
                         #{<<"text">> => <<"Erlang ADK evaluation metric">>}}
                   || Metric <- maps:get(<<"metrics">>, Result, [])],
          Findings = sarif_findings(maps:get(<<"cases">>, Result), [], 0),
          Document = #{<<"version">> => <<"2.1.0">>,
                       <<"$schema">> =>
                           <<"https://json.schemastore.org/sarif-2.1.0.json">>,
                       <<"runs">> => [#{
                           <<"tool">> => #{<<"driver">> => #{
                               <<"name">> => <<"erlang_adk_eval">>,
                               <<"informationUri">> =>
                                   <<"https://github.com/hsalap7/erlang_adk">>,
                               <<"rules">> => Rules}},
                           <<"results">> => Findings}]},
          try jsx:encode(Document) of
              Encoded -> bounded_binary(Encoded, Opts)
          catch
              _:_ -> {error, invalid_eval_sarif}
          end
      end).

-spec annotations(map(), map()) -> {ok, [map()]} | {error, term()}.
annotations(Result0, Options) ->
    with_result(Result0, Options,
      fun(Result, _Opts) ->
          Cases = maps:get(<<"cases">>, Result),
          case length(Cases) =< ?MAX_ANNOTATIONS of
              false -> {error, eval_annotation_limit_exceeded};
              true ->
                  {ok, [annotation(Case)
                        || Case <- Cases,
                           not maps:get(<<"passed">>, Case, false)]}
          end
      end).

with_result(Result0, Options0, Fun) when is_map(Options0) ->
    case {adk_eval_set:encode_result(Result0), normalize_options(Options0)} of
        {{ok, Result}, {ok, Options}} -> Fun(Result, Options);
        {{error, Reason}, _} -> {error, {invalid_eval_export_result,
                                        reason_tag(Reason)}};
        {_, {error, _} = Error} -> Error
    end;
with_result(_Result, _Options, _Fun) ->
    {error, invalid_eval_export_options}.

normalize_options(Options) ->
    Allowed = [suite_name, max_bytes],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Suite = maps:get(suite_name, Options, <<"erlang_adk_eval">>),
    Maximum = maps:get(max_bytes, Options, ?ADK_EVAL_REPORT_MAX_BYTES),
    case {Unknown, valid_text(Suite), is_integer(Maximum),
          Maximum > 0, Maximum =< ?ADK_EVAL_REPORT_MAX_BYTES} of
        {[], true, true, true, true} ->
            {ok, #{suite_name => Suite, max_bytes => Maximum}};
        {[_ | _], _, _, _, _} ->
            {error, {unknown_eval_export_options, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_export_options}
    end.

junit_case(Case) ->
    Id = maps:get(<<"case_id">>, Case),
    Duration = maps:get(<<"duration_ms">>, Case, 0) / 1000,
    Start = [<<"  <testcase classname=\"erlang_adk_eval\" name=\"">>,
             xml(Id), <<"\" time=\"">>, decimal(Duration), <<"\"">>],
    case maps:get(<<"passed">>, Case, false) of
        true -> [Start, <<"/>\n">>];
        false ->
            Status = maps:get(<<"status">>, Case, <<"failed">>),
            [Start, <<">\n    <failure type=\"evaluation\" message=\"">>,
             xml(Status), <<"\"/>\n  </testcase>\n">>]
    end.

sarif_findings([], Acc, _Index) -> lists:reverse(Acc);
sarif_findings([Case | Rest], Acc, Index) when Index < ?MAX_ANNOTATIONS ->
    case maps:get(<<"passed">>, Case, false) of
        true -> sarif_findings(Rest, Acc, Index + 1);
        false ->
            Id = maps:get(<<"case_id">>, Case),
            Finding = #{<<"ruleId">> => <<"evaluation-case">>,
                        <<"level">> => <<"error">>,
                        <<"message">> => #{<<"text">> =>
                            iolist_to_binary([<<"Evaluation case failed: ">>,
                                              Id])},
                        <<"properties">> => #{
                            <<"caseId">> => Id,
                            <<"status">> => maps:get(<<"status">>, Case)}},
            sarif_findings(Rest, [Finding | Acc], Index + 1)
    end;
sarif_findings(_Rest, Acc, _Index) -> lists:reverse(Acc).

annotation(Case) ->
    Id = maps:get(<<"case_id">>, Case),
    Status = maps:get(<<"status">>, Case),
    #{<<"level">> => <<"failure">>,
      <<"title">> => <<"Erlang ADK evaluation regression">>,
      <<"message">> =>
          iolist_to_binary([<<"Case ">>, Id, <<" is ">>, Status]),
      <<"case_id">> => Id,
      <<"status">> => Status}.

bounded_binary(Iodata, Options) ->
    Maximum = maps:get(max_bytes, Options),
    try iolist_to_binary(Iodata) of
        Binary when byte_size(Binary) =< Maximum ->
            {ok, Binary};
        _ -> {error, eval_export_byte_limit_exceeded}
    catch
        _:_ -> {error, invalid_eval_export}
    end.

xml(Binary) ->
    lists:foldl(
      fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
      Binary,
      [{<<"&">>, <<"&amp;">>}, {<<"<">>, <<"&lt;">>},
       {<<">">>, <<"&gt;">>}, {<<"\"">>, <<"&quot;">>},
       {<<"'">>, <<"&apos;">>}]).

decimal(Number) -> float_to_binary(Number, [{decimals, 3}, compact]).

valid_text(Value) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< 256 ->
    try unicode:characters_to_binary(Value) of Value -> true; _ -> false
    catch _:_ -> false end;
valid_text(_) -> false.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> invalid.
