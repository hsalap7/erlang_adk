-module(adk_context_cache_gemini_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, adk_context_cache_gemini_mock).
-define(MODEL, <<"gemini-3.1-flash-lite">>).

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(inets),
    _ = catch cowboy:stop_listener(?LISTENER),
    Table = ets:new(gemini_cache_requests, [ordered_set, public]),
    true = ets:insert(Table, [{sequence, 0}, {mode, success}]),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/v1beta/[...]", ?MODULE,
                          #{request_table => Table}}]}]),
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{port, 0}], #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(?LISTENER),
    BaseUrl = list_to_binary(
                "http://127.0.0.1:" ++ integer_to_list(Port)),
    Previous = application:get_env(erlang_adk, gemini_context_cache),
    ok = application:set_env(
           erlang_adk, gemini_context_cache,
           #{base_url => BaseUrl, api_key => <<"cache-test-key">>,
             request_timeout_ms => 2000}),
    #{table => Table, base_url => BaseUrl, previous => Previous}.

teardown(#{table := Table, previous := Previous}) ->
    _ = catch cowboy:stop_listener(?LISTENER),
    _ = catch ets:delete(Table),
    case Previous of
        {ok, Value} -> application:set_env(
                         erlang_adk, gemini_context_cache, Value);
        undefined -> application:unset_env(
                       erlang_adk, gemini_context_cache)
    end.

gemini_context_cache_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun(State) ->
         [?_test(strict_contract_and_prefix_projection(State)),
          ?_test(remote_lifecycle_is_ttl_bound_and_private(State)),
          ?_test(generate_creates_reuses_and_reports_usage(State)),
          ?_test(short_prefix_bypass_and_fail_closed(State)),
          ?_test(stream_uses_cached_prefix_and_usage(State)),
          ?_test(provider_http_failure_is_content_free(State)),
          ?_test(provider_rate_limit_is_structural(State)),
          ?_test(cached_request_error_hides_remote_name(State))]
     end}.

strict_contract_and_prefix_projection(#{base_url := BaseUrl}) ->
    Capabilities = adk_context_cache_gemini:capabilities(),
    ?assertEqual(true, maps:get(context_cache, Capabilities)),
    ?assertEqual(false, maps:get(response_cache, Capabilities)),
    ?assertEqual([?MODEL], maps:get(models, Capabilities)),
    ?assertEqual({ok, 4096},
                 adk_context_cache_gemini:minimum_prefix_tokens(?MODEL)),
    ?assertEqual(false,
                 adk_context_cache_gemini:supports_model(<<"other">>)),
    ?assertMatch(
       {error, {invalid_gemini_context_cache_options,
                {unknown_keys, [unknown]}}},
       adk_context_cache_gemini:validate_options(#{unknown => true})),
    ?assertEqual(
       {error, {invalid_gemini_context_cache_options, api_key_redacted}},
       adk_context_cache_gemini:validate_options(#{api_key => <<>>})),

    {ok, Cache} = adk_context_cache:start_link(#{}),
    try
        Config = gemini_config(BaseUrl, Cache, bypass),
        ?assertEqual(ok, adk_llm_gemini:validate_config(Config)),
        ?assertMatch(
           {error, {invalid_gemini_option, context_cache, invalid_keys}},
           adk_llm_gemini:validate_config(
             Config#{context_cache =>
                         (maps:get(context_cache, Config))#{extra => true}})),
        ?assertMatch(
           {error, {invalid_gemini_option, context_cache,
                    scope_model_mismatch}},
           adk_llm_gemini:validate_config(
             Config#{context_cache =>
                         (maps:get(context_cache, Config))#{
                           scope => (scope())#{model => <<"other">>}}})),
        Public = adk_llm_gemini:public_config(Config),
        ?assertEqual(false, maps:is_key(context_cache, Public)),
        ?assertNotEqual(<<"cache-test-key">>, maps:get(api_key, Public)),

        History = [#{role => system, content => <<"stable system">>},
                   #{role => user, content => <<"old question">>},
                   #{role => agent, content => <<"old answer">>},
                   #{role => user, content => <<"new question">>}],
        {ok, Prefix} = adk_llm_gemini:cache_prefix(
                         Config, History, [dummy_tool]),
        ?assertEqual(?MODEL, maps:get(<<"model">>, Prefix)),
        ?assertEqual(2, length(maps:get(<<"history_prefix">>, Prefix))),
        ?assertMatch(#{<<"parts">> := [_]},
                     maps:get(<<"system_instruction">>, Prefix)),
        ?assertMatch([#{<<"functionDeclarations">> := [_]}],
                     maps:get(<<"tools">>, Prefix)),
        ?assertEqual(nomatch,
                     binary:match(jsx:encode(Prefix),
                                  <<"cache-test-key">>))
    after adk_context_cache:stop(Cache)
    end.

remote_lifecycle_is_ttl_bound_and_private(#{table := Table}) ->
    clear_requests(Table),
    Prefix = wire_prefix(large_text()),
    Request = create_request(1500, 5000),
    {ok, Resource, Metadata} =
        adk_context_cache_gemini:create(Prefix, Request),
    ?assertEqual(5000, maps:get(<<"cached_token_count">>, Metadata)),
    ?assertEqual(nomatch,
                 binary:match(jsx:encode(Metadata), <<"cache-123">>)),
    {ok, <<"cachedContents/cache-123">>} =
        adk_context_cache_gemini:cached_content_name(Resource, ?MODEL),
    ?assertEqual(
       {error, context_cache_model_mismatch},
       adk_context_cache_gemini:cached_content_name(
         Resource, <<"other-model">>)),

    Create = request_by_path(Table, post, <<"/v1beta/cachedContents">>),
    CreateBody = maps:get(body, Create),
    ?assertEqual(<<"models/", ?MODEL/binary>>,
                 maps:get(<<"model">>, CreateBody)),
    ?assertEqual(<<"1.500s">>, maps:get(<<"ttl">>, CreateBody)),
    ?assertEqual(maps:get(<<"history_prefix">>, Prefix),
                 maps:get(<<"contents">>, CreateBody)),
    ?assertEqual(false, maps:is_key(<<"history_prefix">>, CreateBody)),

    Lifecycle = lifecycle_request(),
    {ok, GetMeta} = adk_context_cache_gemini:get(Resource, Lifecycle),
    ?assertEqual(5000, maps:get(<<"cached_token_count">>, GetMeta)),
    {ok, _UpdateMeta} =
        adk_context_cache_gemini:update(Resource, 2500, Lifecycle),
    Patch = request_by_path(
              Table, patch, <<"/v1beta/cachedContents/cache-123">>),
    ?assertEqual(#{<<"ttl">> => <<"2.500s">>}, maps:get(body, Patch)),
    ok = adk_context_cache_gemini:delete(Resource, Lifecycle),
    ?assertEqual(1, request_count(
                      Table, delete,
                      <<"/v1beta/cachedContents/cache-123">>)).

generate_creates_reuses_and_reports_usage(
  #{table := Table, base_url := BaseUrl}) ->
    clear_requests(Table),
    {ok, Cache} = adk_context_cache:start_link(
                    #{min_prefix_tokens => 1,
                      default_ttl_ms => 10000,
                      max_ttl_ms => 20000}),
    try
        Config = gemini_config(BaseUrl, Cache, bypass),
        History = cacheable_history(),
        Result1 = adk_llm_gemini:generate(Config, History, [dummy_tool]),
        assert_cache_result(Result1, <<"created">>),
        Generate1 = latest_generate(Table),
        assert_cached_wire_payload(Generate1),
        ?assertEqual(1, request_count(
                          Table, post, <<"/v1beta/cachedContents">>)),

        Result2 = adk_llm_gemini:generate(Config, History, [dummy_tool]),
        assert_cache_result(Result2, <<"hit">>),
        ?assertEqual(1, request_count(
                          Table, post, <<"/v1beta/cachedContents">>)),
        ?assertEqual(2, generate_request_count(Table)),

        {ok, Invalidation} = adk_context_cache:invalidate(
                               Cache, adk_context_cache_gemini,
                               scope()),
        ?assertEqual(1, maps:get(<<"entries">>, Invalidation)),
        wait_for_request(
          Table, delete, <<"/v1beta/cachedContents/cache-123">>, 100)
    after adk_context_cache:stop(Cache)
    end.

short_prefix_bypass_and_fail_closed(
  #{table := Table, base_url := BaseUrl}) ->
    clear_requests(Table),
    {ok, BypassCache} = adk_context_cache:start_link(
                          #{failure_mode => bypass,
                            min_prefix_tokens => 1}),
    try
        Config = gemini_config(BaseUrl, BypassCache, bypass),
        Result = adk_llm_gemini:generate(
                   Config,
                   [#{role => system, content => <<"short">>},
                    #{role => user, content => <<"final">>}],
                   [dummy_tool]),
        {ok, {ok, <<"cached response">>}, ProviderMetadata} =
            adk_provider_result:decode(Result),
        CacheMetadata = maps:get(<<"metadata">>, ProviderMetadata),
        Lifecycle = maps:get(<<"lifecycle">>, CacheMetadata),
        ?assertEqual(<<"bypass">>, maps:get(<<"status">>, Lifecycle)),
        ?assertEqual(<<"context_cache_prefix_below_model_minimum">>,
                     maps:get(<<"reason">>, Lifecycle)),
        FullPayload = maps:get(body, latest_generate(Table)),
        ?assertEqual(false, maps:is_key(<<"cachedContent">>, FullPayload)),
        ?assertEqual(true,
                     maps:is_key(<<"system_instruction">>, FullPayload)),
        ?assertEqual(true, maps:is_key(<<"tools">>, FullPayload))
    after adk_context_cache:stop(BypassCache)
    end,

    clear_requests(Table),
    {ok, StrictCache} = adk_context_cache:start_link(
                         #{failure_mode => error,
                           min_prefix_tokens => 1}),
    try
        StrictConfig = gemini_config(BaseUrl, StrictCache, error),
        ?assertEqual(
           {error,
            {context_cache_unavailable,
             context_cache_prefix_below_model_minimum}},
           adk_llm_gemini:generate(
             StrictConfig,
             [#{role => system, content => <<"short">>},
              #{role => user, content => <<"final">>}], [])),
        ?assertEqual(0, generate_request_count(Table))
    after adk_context_cache:stop(StrictCache)
    end.

stream_uses_cached_prefix_and_usage(#{table := Table,
                                      base_url := BaseUrl}) ->
    clear_requests(Table),
    {ok, Cache} = adk_context_cache:start_link(
                    #{min_prefix_tokens => 1,
                      default_ttl_ms => 10000,
                      max_ttl_ms => 20000}),
    try
        Config = gemini_config(BaseUrl, Cache, bypass),
        Parent = self(),
        Ref = make_ref(),
        Result = adk_llm_gemini:stream(
                   Config, cacheable_history(), [dummy_tool],
                   fun(Delta) -> Parent ! {Ref, Delta} end),
        receive
            {Ref, <<"cached stream">>} -> ok
        after 2000 -> error(missing_cached_stream_delta)
        end,
        {ok, streamed, ProviderMetadata} =
            adk_provider_result:decode(Result),
        Metadata = maps:get(<<"metadata">>, ProviderMetadata),
        Usage = maps:get(<<"usage_metadata">>, Metadata),
        ?assertEqual(4096,
                     maps:get(<<"cachedContentTokenCount">>, Usage)),
        StreamRequest = latest_stream(Table),
        assert_cached_wire_payload(StreamRequest)
    after adk_context_cache:stop(Cache)
    end.

provider_http_failure_is_content_free(#{table := Table,
                                        base_url := BaseUrl}) ->
    clear_requests(Table),
    true = ets:insert(Table, {mode, fail_create}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{failure_mode => error, min_prefix_tokens => 1}),
    try
        Config = gemini_config(BaseUrl, Cache, error),
        Result = adk_llm_gemini:generate(
                   Config, cacheable_history(), []),
        ?assertEqual(
           {error, {context_cache_unavailable,
                    gemini_cache_http_status}}, Result),
        Encoded = term_to_binary(Result),
        ?assertEqual(nomatch, binary:match(Encoded, <<"cache-remote-secret">>)),
        ?assertEqual(nomatch, binary:match(Encoded, large_text())),
        ?assertEqual(0, generate_request_count(Table))
    after
        adk_context_cache:stop(Cache),
        true = ets:insert(Table, {mode, success})
    end.

provider_rate_limit_is_structural(#{table := Table,
                                    base_url := BaseUrl}) ->
    clear_requests(Table),
    true = ets:insert(Table, {mode, rate_limit_create}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{failure_mode => error, min_prefix_tokens => 1}),
    try
        Config = gemini_config(BaseUrl, Cache, error),
        Result = adk_llm_gemini:generate(
                   Config, cacheable_history(), []),
        ?assertEqual(
           {error, {context_cache_unavailable,
                    gemini_cache_rate_limited}}, Result),
        ?assertEqual(0, generate_request_count(Table))
    after
        adk_context_cache:stop(Cache),
        true = ets:insert(Table, {mode, success})
    end.

cached_request_error_hides_remote_name(#{table := Table,
                                         base_url := BaseUrl}) ->
    clear_requests(Table),
    true = ets:insert(Table, {mode, fail_generate}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{failure_mode => error, min_prefix_tokens => 1}),
    try
        Config = gemini_config(BaseUrl, Cache, error),
        Result = adk_llm_gemini:generate(
                   Config, cacheable_history(), []),
        ?assertEqual(
           {error, {http_status, 500, context_cache_request_failed}},
           Result),
        Encoded = term_to_binary(Result),
        ?assertEqual(nomatch,
                     binary:match(Encoded,
                                  <<"cachedContents/cache-123">>)),
        ?assertEqual(nomatch,
                     binary:match(Encoded, <<"cache-remote-secret">>))
    after
        adk_context_cache:stop(Cache),
        true = ets:insert(Table, {mode, success})
    end.

gemini_config(BaseUrl, Cache, _Mode) ->
    #{provider => adk_llm_gemini,
      api_key => <<"model-test-key">>,
      base_url => BaseUrl,
      model => ?MODEL,
      context_cache =>
          #{cache => Cache,
            provider => adk_context_cache_gemini,
            scope => scope(),
            ttl_ms => 10000,
            deadline_ms => erlang:monotonic_time(millisecond) + 5000}}.

scope() ->
    #{app => <<"cache-app">>, user => <<"cache-user">>, model => ?MODEL,
      policy => #{context_version => 1, cache_policy => <<"stable">>}}.

normalized_scope() ->
    #{<<"app">> => <<"cache-app">>, <<"user">> => <<"cache-user">>,
      <<"model">> => ?MODEL,
      <<"policy">> =>
          #{<<"context_version">> => 1,
            <<"cache_policy">> => <<"stable">>}}.

wire_prefix(SystemText) ->
    #{<<"model">> => ?MODEL,
      <<"system_instruction">> =>
          #{<<"parts">> => [#{<<"text">> => SystemText}]},
      <<"history_prefix">> =>
          [#{<<"role">> => <<"user">>,
             <<"parts">> => [#{<<"text">> => <<"old question">>}]},
           #{<<"role">> => <<"model">>,
             <<"parts">> => [#{<<"text">> => <<"old answer">>}]}],
      <<"tools">> => []}.

create_request(TtlMs, Estimated) ->
    #{<<"schema_version">> => adk_context_cache:version(),
      <<"scope">> => normalized_scope(),
      <<"ttl_ms">> => TtlMs,
      <<"estimated_context_units">> => Estimated,
      <<"deadline_ms">> => erlang:monotonic_time(millisecond) + 5000}.

lifecycle_request() ->
    #{<<"schema_version">> => adk_context_cache:version(),
      <<"scope">> => normalized_scope(),
      <<"deadline_ms">> => erlang:monotonic_time(millisecond) + 5000}.

cacheable_history() ->
    Stable = large_text(),
    [#{role => system, content => Stable},
     #{role => user, content => <<"old question">>},
     #{role => agent, content => <<"old answer">>},
     #{role => user, content => <<"final request">>}].

large_text() -> binary:copy(<<"stable-prefix ">>, 1800).

assert_cache_result(Result, ExpectedStatus) ->
    {ok, {ok, <<"cached response">>}, ProviderMetadata} =
        adk_provider_result:decode(Result),
    ?assertEqual(<<"context_cache_usage">>,
                 maps:get(<<"type">>, ProviderMetadata)),
    Metadata = maps:get(<<"metadata">>, ProviderMetadata),
    Lifecycle = maps:get(<<"lifecycle">>, Metadata),
    ?assertEqual(ExpectedStatus, maps:get(<<"status">>, Lifecycle)),
    Usage = maps:get(<<"usage_metadata">>, Metadata),
    ?assertEqual(4096,
                 maps:get(<<"cachedContentTokenCount">>, Usage)),
    Encoded = jsx:encode(ProviderMetadata),
    ?assertEqual(nomatch, binary:match(Encoded, <<"cachedContents/cache-123">>)),
    ?assertEqual(nomatch, binary:match(Encoded, <<"cache-test-key">>)).

assert_cached_wire_payload(Request) ->
    Body = maps:get(body, Request),
    ?assertEqual(<<"cachedContents/cache-123">>,
                 maps:get(<<"cachedContent">>, Body)),
    ?assertEqual(false, maps:is_key(<<"system_instruction">>, Body)),
    ?assertEqual(false, maps:is_key(<<"tools">>, Body)),
    [Final] = maps:get(<<"contents">>, Body),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Final)),
    ?assertEqual(
       [#{<<"text">> => <<"final request">>}],
       maps:get(<<"parts">>, Final)).

clear_requests(Table) ->
    [ets:delete(Table, Key) || {Key, _} <- ets:tab2list(Table),
                               is_tuple(Key), element(1, Key) =:= request],
    true = ets:insert(Table, {sequence, 0}),
    ok.

request_count(Table, Method, Path) ->
    length([ok || {{request, _}, #{method := M, path := P}}
                      <- ets:tab2list(Table),
                  M =:= Method, P =:= Path]).

generate_request_count(Table) ->
    length([ok || {{request, _}, #{method := post, path := Path}}
                      <- ets:tab2list(Table),
                  binary:match(Path, <<":generateContent">>) =/= nomatch]).

latest_generate(Table) ->
    latest_matching(
      Table, fun(#{method := post, path := Path}) ->
                 binary:match(Path, <<":generateContent">>) =/= nomatch
             end).

latest_stream(Table) ->
    latest_matching(
      Table, fun(#{method := post, path := Path}) ->
                 binary:match(Path, <<":streamGenerateContent">>) =/= nomatch
             end).

request_by_path(Table, Method, Path) ->
    latest_matching(
      Table, fun(#{method := M, path := P}) ->
                 M =:= Method andalso P =:= Path
             end).

latest_matching(Table, Predicate) ->
    Matches = [{Sequence, Request}
               || {{request, Sequence}, Request} <- ets:tab2list(Table),
                  Predicate(Request)],
    {_Sequence, Latest} = lists:last(lists:sort(Matches)),
    Latest.

wait_for_request(_Table, _Method, _Path, 0) ->
    error(gemini_cache_request_timeout);
wait_for_request(Table, Method, Path, Attempts) ->
    case request_count(Table, Method, Path) > 0 of
        true -> ok;
        false -> timer:sleep(10),
                 wait_for_request(Table, Method, Path, Attempts - 1)
    end.

init(Req0, #{request_table := Table} = State) ->
    Method = method_atom(cowboy_req:method(Req0)),
    Path = cowboy_req:path(Req0),
    {BodyBytes, Req1} = read_body(Req0, <<>>),
    Body = case BodyBytes of
        <<>> -> #{};
        _ -> jsx:decode(BodyBytes, [return_maps])
    end,
    Sequence = ets:update_counter(Table, sequence, 1),
    Request = #{method => Method, path => Path, body => Body,
                headers => cowboy_req:headers(Req1)},
    true = ets:insert(Table, {{request, Sequence}, Request}),
    Mode = case ets:lookup(Table, mode) of
        [{mode, Value}] -> Value;
        [] -> success
    end,
    Req2 = reply(Method, Path, Mode, Req1),
    {ok, Req2, State}.

read_body(Req, Acc) ->
    case cowboy_req:read_body(Req) of
        {ok, Data, Req1} -> {<<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_body(Req1, <<Acc/binary, Data/binary>>)
    end.

reply(post, <<"/v1beta/cachedContents">>, fail_create, Req) ->
    cowboy_req:reply(
      500, #{<<"content-type">> => <<"application/json">>},
      <<"{\"error\":{\"message\":\"cache-remote-secret\"}}">>, Req);
reply(post, <<"/v1beta/cachedContents">>, rate_limit_create, Req) ->
    cowboy_req:reply(
      429, #{<<"content-type">> => <<"application/json">>},
      <<"{\"error\":{\"message\":\"quota detail must stay private\"}}">>,
      Req);
reply(post, <<"/v1beta/cachedContents">>, _Mode, Req) ->
    json_reply(200, cached_content_response(), Req);
reply(get, <<"/v1beta/cachedContents/cache-123">>, _Mode, Req) ->
    json_reply(200, cached_content_response(), Req);
reply(patch, <<"/v1beta/cachedContents/cache-123">>, _Mode, Req) ->
    json_reply(200, cached_content_response(), Req);
reply(delete, <<"/v1beta/cachedContents/cache-123">>, _Mode, Req) ->
    cowboy_req:reply(200, #{}, <<>>, Req);
reply(post, _Path, fail_generate, Req) ->
    cowboy_req:reply(
      500, #{<<"content-type">> => <<"application/json">>},
      <<"{\"error\":{\"message\":\"cachedContents/cache-123 "
        "cache-remote-secret\"}}">>, Req);
reply(post, Path, _Mode, Req) ->
    case binary:match(Path, <<":streamGenerateContent">>) of
        nomatch -> json_reply(200, generate_response(), Req);
        _ ->
            Frame1 = jsx:encode(
                       #{<<"candidates">> =>
                             [#{<<"content">> =>
                                    #{<<"parts">> =>
                                          [#{<<"text">> =>
                                                 <<"cached stream">>}]}}]}),
            Frame2 = jsx:encode(
                       #{<<"usageMetadata">> => usage_metadata()}),
            Body = <<"data: ", Frame1/binary, "\n\n",
                     "data: ", Frame2/binary, "\n\n">>,
            cowboy_req:reply(
              200, #{<<"content-type">> => <<"text/event-stream">>},
              Body, Req)
    end;
reply(_Method, _Path, _Mode, Req) ->
    cowboy_req:reply(404, #{}, <<>>, Req).

cached_content_response() ->
    #{<<"name">> => <<"cachedContents/cache-123">>,
      <<"model">> => <<"models/", ?MODEL/binary>>,
      <<"expireTime">> => <<"2026-07-14T12:00:00Z">>,
      <<"usageMetadata">> => #{<<"totalTokenCount">> => 5000}}.

generate_response() ->
    #{<<"candidates">> =>
          [#{<<"content">> =>
                 #{<<"parts">> =>
                       [#{<<"text">> => <<"cached response">>}]}}],
      <<"usageMetadata">> => usage_metadata()}.

usage_metadata() ->
    #{<<"cachedContentTokenCount">> => 4096,
      <<"promptTokenCount">> => 4200,
      <<"candidatesTokenCount">> => 1,
      <<"totalTokenCount">> => 4201}.

json_reply(Status, Value, Req) ->
    cowboy_req:reply(
      Status, #{<<"content-type">> => <<"application/json">>},
      jsx:encode(Value), Req).

method_atom(<<"POST">>) -> post;
method_atom(<<"GET">>) -> get;
method_atom(<<"PATCH">>) -> patch;
method_atom(<<"DELETE">>) -> delete.
