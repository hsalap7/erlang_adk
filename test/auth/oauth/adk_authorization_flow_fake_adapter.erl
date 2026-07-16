-module(adk_authorization_flow_fake_adapter).

-behaviour(adk_authorization_code_adapter).

-export([validate_context/1, authorization_uri/2, exchange_code/3]).

validate_context(#{marker := Marker,
                   client_id := ClientId,
                   client_secret := ClientSecret} = Context) ->
    Allowed = [marker, client_id, client_secret, delay_ms, padding,
               authorization_delay_ms, authorization_mode, observer],
    case map_size(maps:without(Allowed, Context)) =:= 0 andalso
         valid_binary(Marker) andalso valid_binary(ClientId) andalso
         valid_binary(ClientSecret) andalso
         valid_delay(maps:get(delay_ms, Context, 0)) andalso
         valid_delay(maps:get(authorization_delay_ms, Context, 0)) andalso
         valid_padding(maps:get(padding, Context, <<>>)) andalso
         valid_authorization_mode(
           maps:get(authorization_mode, Context, normal)) andalso
         valid_observer(maps:get(observer, Context, undefined)) of
        true -> ok;
        false -> {error, invalid_context}
    end;
validate_context(_Context) ->
    {error, invalid_context}.

authorization_uri(#{marker := Marker, client_id := ClientId} = Context,
                  Opts) ->
    notify(Context, {authorization_uri_started, self()}),
    timer:sleep(maps:get(authorization_delay_ms, Context, 0)),
    case maps:get(authorization_mode, Context, normal) of
        crash -> erlang:error({authorization_uri_failed,
                               maps:get(client_secret, Context)});
        heap -> exhaust_heap([]);
        normal -> authorization_uri_result(Marker, ClientId, Opts)
    end.

authorization_uri_result(Marker, ClientId, Opts) ->
    Verifier = maps:get(pkce_verifier, Opts),
    Challenge = base64:encode(crypto:hash(sha256, Verifier),
                              #{mode => urlsafe, padding => false}),
    Pairs0 = [{<<"response_type">>, <<"code">>},
              {<<"client_id">>, ClientId},
              {<<"redirect_uri">>, maps:get(redirect_uri, Opts)},
              {<<"state">>, maps:get(state, Opts)},
              {<<"nonce">>, maps:get(nonce, Opts)},
              {<<"code_challenge">>, Challenge},
              {<<"code_challenge_method">>, <<"S256">>},
              {<<"scope">>, iolist_to_binary(
                                lists:join(<<" ">>,
                                           maps:get(scopes, Opts)))}],
    Pairs = case maps:get(resource, Opts) of
        undefined -> Pairs0;
        Resource -> [{<<"resource">>, Resource} | Pairs0]
    end,
    {ok, <<"https://", Marker/binary,
           ".identity.example/authorize?",
           (uri_string:compose_query(Pairs))/binary>>}.

exchange_code(#{marker := Marker,
                client_id := ClientId,
                client_secret := ClientSecret} = Context,
              Code, Opts) ->
    notify(Context, {exchange_started, self(), Code}),
    timer:sleep(maps:get(delay_ms, Context, 0)),
    Prefix = <<"code:", Marker/binary, ":">>,
    case Code of
        <<"heap">> -> exhaust_heap([]);
        <<"crash">> -> erlang:error({exchange_failed, ClientSecret});
        _ -> exchange_result(Code, Prefix, Marker, ClientId,
                             ClientSecret, Opts)
    end.

exchange_result(Code, Prefix, Marker, ClientId, ClientSecret, Opts) ->
    case {Code, provider_subject(Code, Prefix), valid_exchange_opts(Opts)} of
        {<<"oversized-token">>, _, true} ->
            {ok, #{kind => oauth_refresh_token,
                   client_id => ClientId,
                   client_secret => ClientSecret,
                   refresh_token => binary:copy(<<"x">>, 70000),
                   expected_subject => <<"bounded-provider-subject">>}};
        {_, {ok, ProviderSubject}, true} ->
            {ok, #{kind => oauth_refresh_token,
                   client_id => ClientId,
                   client_secret => ClientSecret,
                   refresh_token => <<"refresh:", Marker/binary, ":",
                                      ProviderSubject/binary>>,
                   expected_subject => ProviderSubject}};
        {_, leak, _} ->
            {error, {endpoint_error, ClientSecret,
                     maps:get(pkce_verifier, Opts)}};
        _ ->
            {error, invalid_code_or_subject}
    end.

valid_exchange_opts(#{state := <<"oauth_state_", _/binary>>,
                      nonce := <<"oauth_nonce_", _/binary>>,
                      pkce_verifier := Verifier,
                      redirect_uri := <<"https://", _/binary>>,
                      scopes := Scopes}) ->
    is_binary(Verifier) andalso byte_size(Verifier) =:= 43 andalso
    is_list(Scopes) andalso Scopes =/= [];
valid_exchange_opts(_Opts) -> false.

provider_subject(<<"leak">>, _Prefix) -> leak;
provider_subject(Code, Prefix) ->
    PrefixSize = byte_size(Prefix),
    case Code of
        <<Prefix:PrefixSize/binary, Subject/binary>>
          when byte_size(Subject) > 0, byte_size(Subject) =< 4096,
               Subject =/= <<"missing-sub">>, Subject =/= <<"invalid-sub">> ->
            {ok, Subject};
        _ -> error
    end.

valid_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_binary(_) -> false.

valid_delay(Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< 5000.

valid_padding(Value) when is_binary(Value) -> true;
valid_padding(_) -> false.

valid_authorization_mode(normal) -> true;
valid_authorization_mode(crash) -> true;
valid_authorization_mode(heap) -> true;
valid_authorization_mode(_) -> false.

valid_observer(undefined) -> true;
valid_observer(Pid) -> is_pid(Pid).

notify(Context, Message) ->
    case maps:get(observer, Context, undefined) of
        Observer when is_pid(Observer) -> Observer ! Message;
        undefined -> ok
    end.

exhaust_heap(Acc) ->
    exhaust_heap([make_ref(), make_ref(), make_ref(), make_ref() | Acc]).
