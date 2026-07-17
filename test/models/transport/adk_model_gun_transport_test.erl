-module(adk_model_gun_transport_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/:mode", ?MODULE, #{}}]}]),
    {ok, _} = cowboy:start_clear(adk_model_transport_test,
                                 [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(adk_model_transport_test),
    #{base_url => list_to_binary(
                     "http://127.0.0.1:" ++ integer_to_list(Port))}.

teardown(_State) ->
    ok = cowboy:stop_listener(adk_model_transport_test).

model_gun_transport_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(State) ->
         [?_test(streams_with_inline_backpressure(State)),
          ?_test(returns_bounded_error_body_without_callback(State)),
          ?_test(enforces_stream_size_limit(State)),
          ?_test(propagates_sanitized_callback_failure(State)),
          ?_test(rejects_private_target_by_default(State)),
          ?_test(reuses_hardened_sync_transport(State)),
          ?_test(rejects_headers_consistently_for_sync_and_stream(State))]
     end}.

streams_with_inline_backpressure(#{base_url := BaseUrl}) ->
    Parent = self(),
    Callback = fun(Chunk) -> Parent ! {chunk, Chunk}, ok end,
    {ok, #{status := 200, body := <<>>}} =
        adk_model_gun_transport:stream(
          default, request(BaseUrl, <<"/stream">>), Callback),
    Chunks = drain_chunks([]),
    ?assertEqual(<<"data: one\n\ndata: two\n\n">>,
                 iolist_to_binary(Chunks)).

returns_bounded_error_body_without_callback(#{base_url := BaseUrl}) ->
    Parent = self(),
    Callback = fun(Chunk) -> Parent ! {unexpected, Chunk}, ok end,
    {ok, #{status := 429, body := Body}} =
        adk_model_gun_transport:stream(
          default, request(BaseUrl, <<"/error">>), Callback),
    ?assertEqual(<<"bounded-error">>, Body),
    receive
        {unexpected, _} -> ?assert(false)
    after 0 -> ok
    end.

enforces_stream_size_limit(#{base_url := BaseUrl}) ->
    Request = (request(BaseUrl, <<"/large">>))#{max_response_bytes => 4},
    ?assertEqual(
       {error, response_too_large},
       adk_model_gun_transport:stream(default, Request, fun(_) -> ok end)).

propagates_sanitized_callback_failure(#{base_url := BaseUrl}) ->
    ?assertEqual(
       {error, {stream_callback_failed, error}},
       adk_model_gun_transport:stream(
         default, request(BaseUrl, <<"/stream">>),
         fun(_Chunk) -> error(<<"secret-callback-reason">>) end)).

rejects_private_target_by_default(#{base_url := BaseUrl}) ->
    Request = (request(BaseUrl, <<"/stream">>))#{allow_private_hosts => false},
    ?assertEqual(
       {error, private_address_rejected},
       adk_model_gun_transport:stream(default, Request, fun(_) -> ok end)).

reuses_hardened_sync_transport(#{base_url := BaseUrl}) ->
    {ok, #{status := 200, body := <<"sync-ok">>}} =
        adk_model_gun_transport:request(
          default, request(BaseUrl, <<"/sync">>)).

rejects_headers_consistently_for_sync_and_stream(#{base_url := BaseUrl}) ->
    InvalidHeaders =
        [[{<<"x-test">>, <<"ok\r\ninjected: yes">>}],
         [{<<"host">>, <<"attacker.example">>}],
         [{<<"x-id">>, <<"one">>}, {<<"X-ID">>, <<"two">>}],
         [{<<"x">>, binary:copy(<<"v">>, 65536)}]],
    lists:foreach(
      fun(Headers) ->
          Request = (request(BaseUrl, <<"/stream">>))#{headers => Headers},
          ?assertEqual(
             {error, invalid_request},
             adk_model_gun_transport:request(default, Request)),
          ?assertEqual(
             {error, invalid_request},
             adk_model_gun_transport:stream(
               default, Request, fun(_) -> ok end))
      end, InvalidHeaders).

request(BaseUrl, Path) ->
    #{method => <<"POST">>,
      url => <<BaseUrl/binary, Path/binary>>,
      headers => [{<<"content-type">>, <<"application/json">>}],
      body => <<"{}">>,
      timeout_ms => 2000,
      max_response_bytes => 1024,
      follow_redirects => false,
      allowed_schemes => [<<"http">>],
      allowed_hosts => [<<"127.0.0.1">>],
      allow_private_hosts => true}.

drain_chunks(Acc) ->
    receive
        {chunk, Chunk} -> drain_chunks([Chunk | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

init(Req0, State) ->
    Mode = cowboy_req:binding(mode, Req0),
    handle(Mode, Req0, State).

handle(<<"stream">>, Req0, State) ->
    Req1 = cowboy_req:stream_reply(
             200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    ok = cowboy_req:stream_body(<<"data: one\n\n">>, nofin, Req1),
    ok = cowboy_req:stream_body(<<"data: two\n\n">>, fin, Req1),
    {ok, Req1, State};
handle(<<"error">>, Req0, State) ->
    Req1 = cowboy_req:reply(429, #{}, <<"bounded-error">>, Req0),
    {ok, Req1, State};
handle(<<"large">>, Req0, State) ->
    Req1 = cowboy_req:reply(200, #{}, <<"too-large">>, Req0),
    {ok, Req1, State};
handle(<<"sync">>, Req0, State) ->
    Req1 = cowboy_req:reply(200, #{}, <<"sync-ok">>, Req0),
    {ok, Req1, State}.
