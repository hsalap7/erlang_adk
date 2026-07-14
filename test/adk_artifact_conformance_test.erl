-module(adk_artifact_conformance_test).
-include_lib("eunit/include/eunit.hrl").

-define(SCOPE, {session, <<"conformance-app">>, <<"user">>, <<"session">>}).

artifact_adapters_conform_test_() ->
    [{"ETS artifact adapter", fun ets_conformance/0},
     {"filesystem artifact adapter", fun fs_conformance/0}].

ets_conformance() ->
    {ok, Pid} = adk_artifact_ets:start_link(#{}),
    try run_conformance(adk_artifact_ets, Pid)
    after _ = adk_artifact_ets:stop(Pid)
    end.

fs_conformance() ->
    Root = temp_root(),
    try
        {ok, Pid} = adk_artifact_fs:start_link(#{root => Root}),
        try run_conformance(adk_artifact_fs, Pid)
        after _ = adk_artifact_fs:stop(Pid)
        end
    after _ = file:del_dir_r(Root)
    end.

run_conformance(Module, Pid) ->
    {ok, #{api_version := 1, immutable_versions := true}} =
        Module:capabilities(Pid),
    Name = <<"reports/conformance.txt">>,
    {ok, #{version := 1}} = Module:put(
                               Pid, ?SCOPE, Name, <<"one">>,
                               #{mime_type => <<"text/plain">>}),
    {ok, #{version := 2}} = Module:put(Pid, ?SCOPE, Name, <<"two">>, #{}),
    {ok, #{data := <<"one">>}} = Module:get(Pid, ?SCOPE, Name, 1),
    {ok, #{data := <<"two">>}} = Module:get(Pid, ?SCOPE, Name, latest),
    {ok, #{scope := ?SCOPE, items := [Name],
           next_cursor := undefined}} =
        Module:list_names(Pid, ?SCOPE, #{limit => 1}),
    {ok, #{items := [First], next_cursor := 1}} =
        Module:list_versions(Pid, ?SCOPE, Name, #{limit => 1}),
    ?assertEqual(1, maps:get(version, First)),
    ?assert(not maps:is_key(data, First)),
    ok = Module:delete(Pid, ?SCOPE, Name, latest),
    {ok, #{version := 1}} = Module:get(Pid, ?SCOPE, Name, latest),
    ok = Module:delete(Pid, ?SCOPE, Name, all),
    {ok, #{version := 3}} = Module:put(Pid, ?SCOPE, Name, <<"three">>, #{}),
    Other = {session, <<"conformance-app">>, <<"other-user">>, <<"session">>},
    {ok, #{version := 1}} = Module:put(Pid, Other, Name, <<"isolated">>, #{}),
    {ok, #{data := <<"three">>}} = Module:get(Pid, ?SCOPE, Name, latest),
    {ok, #{data := <<"isolated">>}} = Module:get(Pid, Other, Name, latest).

temp_root() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    filename:join(Base, "erlang-adk-artifact-conformance-" ++
                        integer_to_list(erlang:unique_integer([positive]))).
