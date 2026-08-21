%% @doc Opt-in release gate against the official MCP Python and TypeScript
%% SDKs. Dependencies are provisioned separately by the pinned bootstrap; this
%% test never downloads packages and communicates only with loopback fixtures.
-module(adk_mcp_external_sdk_conformance_test).
-include_lib("eunit/include/eunit.hrl").

-define(COMMAND_TIMEOUT_MS, 45000).
-define(TRIGGER_TIMEOUT_MS, 30000).

external_sdk_conformance_test_() ->
    case os:getenv("ADK_MCP_EXTERNAL_CONFORMANCE") of
        "1" -> {timeout, 240, fun external_sdk_conformance/0};
        _ -> []
    end.

external_sdk_conformance() ->
    Harness = require_env("MCP_CONFORMANCE_HARNESS_DIR"),
    Node = require_env("MCP_CONFORMANCE_NODE"),
    Python = require_env("MCP_CONFORMANCE_PYTHON"),
    TypeScriptClient = filename:join(Harness, "typescript_client.mjs"),
    PythonClient = filename:join(Harness, "python_client.py"),
    ok = run_modern_case(
           typescript, Node, [TypeScriptClient, "modern"]),
    ok = run_modern_case(
           python, Python, [PythonClient, "modern"]),
    ok = run_legacy_case(
           typescript, Node, [TypeScriptClient, "legacy"]),
    ok = run_legacy_case(
           python, Python, [PythonClient, "legacy"]).

run_modern_case(Sdk, Executable, PrefixArgs) ->
    {ok, Fixture} = adk_mcp_external_sdk_fixture:start(#{}),
    #{endpoint := #{url := Url}} = Fixture,
    Trigger = trigger_path(Sdk),
    _ = file:delete(Trigger),
    Parent = self(),
    Watcher = spawn(
                fun() ->
                    await_generation_trigger(
                      Fixture, Trigger, Parent,
                      erlang:monotonic_time(millisecond) +
                          ?TRIGGER_TIMEOUT_MS)
                end),
    try
        {Status, Output} = run_command(
                             Executable,
                             PrefixArgs ++ [binary_to_list(Url), Trigger],
                             ?COMMAND_TIMEOUT_MS),
        report_result(Sdk, modern, Status, Output),
        ?assertEqual(0, Status),
        ?assertNotEqual(nomatch, binary:match(Output, <<"pass">>)),
        receive
            {generation_replaced, Watcher,
             {ok, #{changed := #{tools := true}}}} -> ok;
            {generation_replaced, Watcher, Other} ->
                ?assertEqual({ok, expected_tools_generation_change}, Other)
        after 2000 ->
            ?assert(false)
        end
    after
        exit(Watcher, kill),
        _ = file:delete(Trigger),
        ok = adk_mcp_external_sdk_fixture:stop(Fixture)
    end.

run_legacy_case(Sdk, Executable, PrefixArgs) ->
    {ok, Fixture} = adk_mcp_external_sdk_fixture:start(
                      #{modern_enabled => false,
                        modern_subscriptions => false,
                        legacy_sse_compat => false}),
    #{endpoint := #{url := Url}} = Fixture,
    try
        {Status, Output} = run_command(
                             Executable,
                             PrefixArgs ++ [binary_to_list(Url)],
                             ?COMMAND_TIMEOUT_MS),
        report_result(Sdk, legacy, Status, Output),
        ?assertEqual(0, Status),
        ?assertNotEqual(nomatch, binary:match(Output, <<"pass">>)),
        ok
    after
        ok = adk_mcp_external_sdk_fixture:stop(Fixture)
    end.

await_generation_trigger(Fixture, Trigger, Parent, Deadline) ->
    case file:read_file(Trigger) of
        {ok, _} ->
            Result = adk_mcp_external_sdk_fixture:replace_generation(
                       Fixture, <<"fixture.echo.v2">>),
            Parent ! {generation_replaced, self(), Result};
        {error, enoent} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(20),
                    await_generation_trigger(
                      Fixture, Trigger, Parent, Deadline);
                false ->
                    Parent ! {generation_replaced, self(), timeout}
            end;
        {error, Reason} ->
            Parent ! {generation_replaced, self(), {error, Reason}}
    end.

run_command(Executable, Args, Timeout) ->
    Port = open_port(
             {spawn_executable, Executable},
             [binary, use_stdio, stderr_to_stdout, exit_status, eof,
              {args, Args}]),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect_command(Port, [], Deadline).

collect_command(Port, Acc, Deadline) ->
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            collect_command(Port, [Data | Acc], Deadline);
        {Port, eof} ->
            collect_command(Port, Acc, Deadline);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after Remaining ->
        _ = catch port_close(Port),
        {124, iolist_to_binary(lists:reverse(Acc))}
    end.

report_result(Sdk, Mode, Status, Output) ->
    io:format("~nMCP external SDK ~p/~p exit=~p~n~ts", 
              [Sdk, Mode, Status, Output]).

trigger_path(Sdk) ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    filename:join(
      "/private/tmp",
      "erlang-adk-mcp-" ++ atom_to_list(Sdk) ++ "-" ++ Suffix ++
          ".trigger").

require_env(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_conformance_environment, Name});
        Value -> Value
    end.
