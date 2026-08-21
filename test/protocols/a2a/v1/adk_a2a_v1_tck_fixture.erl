%% @doc Deterministic external System Under Test for the official A2A 1.0 TCK.
%%
%% This fixture deliberately lives in the test profile.  It exercises the
%% production Cowboy handler, JSON-RPC dispatcher, task server, SSE stream,
%% push transport, and codecs while providing only the scenario-specific
%% executor behavior required by the TCK.
-module(adk_a2a_v1_tck_fixture).

-export([start/0, execute/2]).

-define(LISTENER, adk_a2a_v1_tck_listener).

-spec start() -> no_return().
start() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Port = fixture_port(),
    BaseUrl = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    {ok, Card} = card(BaseUrl, <<"Erlang ADK A2A TCK fixture">>),
    {ok, ExtendedCard} = card(
                           BaseUrl,
                           <<"Erlang ADK A2A TCK extended fixture">>),
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined,
                       card => Card,
                       extended_card => ExtendedCard,
                       executor => {?MODULE, execute},
                       task_timeout => 30000,
                       retention_ms => 600000,
                       max_tasks => 10000,
                       max_active => 500,
                       max_events => 256,
                       max_subscribers_per_task => 32,
                       push_policy => push_policy()}),
    Auth = fun(_Operation, _Headers, _Summary) ->
        {ok, #{subject => <<"a2a-tck">>}, <<"a2a-tck">>}
    end,
    Handler = #{server => Server,
                auth => Auth,
                max_body_bytes => 1048576,
                sse_heartbeat_ms => 1000},
    Dispatch = cowboy_router:compile(
                 [{'_', [
                   {"/.well-known/agent-card.json", adk_a2a_v1_handler,
                    Handler#{endpoint => card}},
                   {"/extendedAgentCard", adk_a2a_v1_handler,
                    Handler#{endpoint => extended_card}},
                   {"/", adk_a2a_v1_handler,
                    Handler#{endpoint => jsonrpc}}
                 ]}]),
    _ = catch cowboy:stop_listener(?LISTENER),
    {ok, _} = cowboy:start_clear(
                ?LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    io:format("A2A_TCK_FIXTURE_READY ~s~n", [BaseUrl]),
    receive
        stop -> ok
    end,
    _ = catch cowboy:stop_listener(?LISTENER),
    _ = catch gen_server:stop(Server),
    erlang:halt(0).

-spec execute(map(), fun((term()) -> term())) -> term().
execute(#{message := Message}, Emit) ->
    MessageId = maps:get(<<"messageId">>, Message, <<>>),
    execute_scenario(MessageId, Emit).

execute_scenario(MessageId, _Emit) ->
    case scenario(MessageId) of
        artifact_file_url ->
            {ok, artifact(
                   <<"artifact-file-url">>,
                   #{<<"url">> => <<"https://example.com/output.txt">>,
                     <<"filename">> => <<"output.txt">>,
                     <<"mediaType">> => <<"text/plain">>})};
        artifact_file ->
            {ok, artifact(
                   <<"artifact-file">>,
                   #{<<"raw">> => base64:encode(<<"tck">>),
                     <<"filename">> => <<"output.txt">>,
                     <<"mediaType">> => <<"text/plain">>})};
        artifact_text ->
            {ok, artifact(
                   <<"artifact-text">>,
                   #{<<"text">> => <<"Generated text content">>,
                     <<"mediaType">> => <<"text/plain">>})};
        artifact_data ->
            {ok, artifact(
                   <<"artifact-data">>,
                   #{<<"data">> => #{<<"key">> => <<"value">>,
                                      <<"count">> => 42},
                     <<"mediaType">> => <<"application/json">>})};
        stream_artifact_text ->
            {ok, artifact(
                   <<"stream-artifact-text">>,
                   #{<<"text">> => <<"Streamed text content">>,
                     <<"mediaType">> => <<"text/plain">>})};
        stream_artifact_file ->
            {ok, artifact(
                   <<"stream-artifact-file">>,
                   #{<<"raw">> => base64:encode(<<"tck">>),
                     <<"filename">> => <<"output.txt">>,
                     <<"mediaType">> => <<"text/plain">>})};
        message_response ->
            {message, agent_message(<<"Direct message response">>)};
        input_required ->
            {input_required, undefined};
        reject_task ->
            {rejected, <<"rejected">>};
        stream_001 ->
            {ok, artifact(
                   <<"stream-001">>,
                   #{<<"text">> => <<"Stream hello from TCK">>,
                     <<"mediaType">> => <<"text/plain">>})};
        stream_002 ->
            {message, agent_message(<<"Stream message-only response">>)};
        stream_003 ->
            {ok, artifact(
                   <<"stream-003">>,
                   #{<<"text">> => <<"Stream task lifecycle">>,
                     <<"mediaType">> => <<"text/plain">>})};
        stream_ordering ->
            {ok, artifact(
                   <<"stream-ordering">>,
                   #{<<"text">> => <<"Ordered output">>,
                     <<"mediaType">> => <<"text/plain">>})};
        stream_chunked ->
            stream_chunks(_Emit);
        resubscribe ->
            timer:sleep(4000),
            {ok, <<"resubscribe complete">>};
        complete_task ->
            {ok, <<"Hello from TCK">>};
        default ->
            {ok, <<"Hello from TCK">>}
    end.

scenario(MessageId) ->
    Prefixes = [
      {<<"tck-artifact-file-url">>, artifact_file_url},
      {<<"tck-artifact-file">>, artifact_file},
      {<<"tck-artifact-text">>, artifact_text},
      {<<"tck-artifact-data">>, artifact_data},
      {<<"tck-stream-artifact-chunked">>, stream_chunked},
      {<<"tck-stream-artifact-text">>, stream_artifact_text},
      {<<"tck-stream-artifact-file">>, stream_artifact_file},
      {<<"tck-message-response">>, message_response},
      {<<"tck-input-required">>, input_required},
      {<<"tck-reject-task">>, reject_task},
      {<<"tck-stream-ordering-001">>, stream_ordering},
      {<<"tck-stream-001">>, stream_001},
      {<<"tck-stream-002">>, stream_002},
      {<<"tck-stream-003">>, stream_003},
      {<<"test-resubscribe-message-id">>, resubscribe},
      {<<"tck-complete-task">>, complete_task}
    ],
    scenario(MessageId, Prefixes).

scenario(_MessageId, []) -> default;
scenario(MessageId, [{Prefix, Name} | Rest]) ->
    case binary:match(MessageId, Prefix) of
        {0, _} -> Name;
        _ -> scenario(MessageId, Rest)
    end.

stream_chunks(Emit) ->
    ArtifactId = <<"stream-artifact-chunked">>,
    ok = Emit({artifact,
               artifact(ArtifactId,
                        #{<<"text">> => <<"chunk-1 ">>,
                          <<"mediaType">> => <<"text/plain">>}),
               true, false}),
    ok = Emit({artifact,
               artifact(ArtifactId,
                        #{<<"text">> => <<"chunk-2">>,
                          <<"mediaType">> => <<"text/plain">>}),
               true, true}),
    {message, agent_message(<<"Stream complete">>)}.

artifact(Id, Part) ->
    #{<<"artifactId">> => Id, <<"parts">> => [Part]}.

agent_message(Text) ->
    #{<<"role">> => <<"ROLE_AGENT">>,
      <<"parts">> => [#{<<"text">> => Text,
                         <<"mediaType">> => <<"text/plain">>}]}.

card(BaseUrl, Name) ->
    adk_a2a_v1_card:new(
      #{url => BaseUrl,
        name => Name,
        description => <<"Official A2A 1.0 TCK conformance fixture">>,
        version => <<"1.0.0">>,
        streaming => true,
        push_notifications => true,
        extended_agent_card => true,
        default_input_modes => [<<"text/plain">>,
                                <<"application/json">>,
                                <<"application/octet-stream">>],
        default_output_modes => [<<"text/plain">>,
                                 <<"application/json">>,
                                 <<"application/octet-stream">>]}).

push_policy() ->
    #{allow_http_loopback => true,
      allowed_hosts => any,
      allowed_private_hosts => [<<"localhost">>, <<"127.0.0.1">>],
      resolver => fun fixture_resolver/1,
      timeout_ms => 5000,
      connect_timeout_ms => 2000,
      retry_base_ms => 10,
      max_attempts => 2}.

fixture_resolver(<<"localhost">>) -> [{127, 0, 0, 1}];
fixture_resolver(<<"127.0.0.1">>) -> [{127, 0, 0, 1}];
fixture_resolver(_Host) -> [{93, 184, 216, 34}].

fixture_port() ->
    case os:getenv("A2A_TCK_PORT") of
        false -> 9999;
        Value ->
            try list_to_integer(Value) of
                Port when Port > 0, Port =< 65535 -> Port;
                _ -> erlang:error(invalid_a2a_tck_port)
            catch
                error:badarg -> erlang:error(invalid_a2a_tck_port)
            end
    end.
