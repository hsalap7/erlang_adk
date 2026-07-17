%% @doc Opt-in supervision for Oidcc provider configuration workers.
%%
%% Starting this supervisor with its default options starts no network-facing
%% children. Each configured provider uses a pre-existing atom or pid name;
%% issuer names are never converted into atoms at runtime.
-module(adk_oidc_provider_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1, child_spec/1, provider_children/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> supervisor:start_link(?MODULE, Opts);
        Name when is_atom(Name), Name =/= undefined ->
            supervisor:start_link({local, Name}, ?MODULE, Opts)
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec provider_children([map()]) ->
    {ok, [supervisor:child_spec()]} | {error, invalid_provider_config}.
provider_children(Providers) when is_list(Providers) ->
    case normalize_providers(Providers, [], []) of
        {ok, Normalized} ->
            {ok, [provider_child(Provider) || Provider <- Normalized]};
        error ->
            {error, invalid_provider_config}
    end;
provider_children(_Providers) ->
    {error, invalid_provider_config}.

init(Opts) ->
    Providers = maps:get(providers, Opts, []),
    case provider_children(Providers) of
        {ok, Children} ->
            SupFlags = #{strategy => one_for_one,
                         intensity => 5,
                         period => 10},
            {ok, {SupFlags, Children}};
        {error, invalid_provider_config} ->
            erlang:error(invalid_oidc_provider_configuration)
    end.

normalize_providers([], _Names, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_providers([Provider | Rest], Names, Acc) when is_map(Provider) ->
    case normalize_provider(Provider) of
        {ok, #{name := Name} = Normalized} ->
            case lists:member(Name, Names) of
                true -> error;
                false -> normalize_providers(Rest, [Name | Names],
                                             [Normalized | Acc])
            end;
        error -> error
    end;
normalize_providers(_Providers, _Names, _Acc) -> error.

normalize_provider(Provider) ->
    AllowedKeys = [name, issuer, provider_configuration_opts,
                   backoff_min, backoff_max, backoff_type],
    Name = maps:get(name, Provider, undefined),
    Issuer = maps:get(issuer, Provider, undefined),
    ProviderOpts = maps:get(provider_configuration_opts, Provider, #{}),
    BackoffMin = maps:get(backoff_min, Provider, 1000),
    BackoffMax = maps:get(backoff_max, Provider, 30000),
    BackoffType = maps:get(backoff_type, Provider, random_exponential),
    case unknown_keys(Provider, AllowedKeys) =:= [] andalso
         is_atom(Name) andalso Name =/= undefined andalso
         valid_issuer(Issuer) andalso is_map(ProviderOpts) andalso
         not contains_secret_key(ProviderOpts) andalso
         is_integer(BackoffMin) andalso BackoffMin > 0 andalso
         is_integer(BackoffMax) andalso BackoffMax >= BackoffMin andalso
         lists:member(BackoffType,
                      [stop, exponential, random, random_exponential]) of
        true ->
            {ok, #{name => Name,
                   issuer => Issuer,
                   provider_configuration_opts => ProviderOpts,
                   backoff_min => BackoffMin,
                   backoff_max => BackoffMax,
                   backoff_type => BackoffType}};
        false -> error
    end.

provider_child(#{name := Name} = Provider) ->
    WorkerOpts = #{name => {local, Name},
                   issuer => maps:get(issuer, Provider),
                   provider_configuration_opts =>
                       maps:get(provider_configuration_opts, Provider),
                   backoff_min => maps:get(backoff_min, Provider),
                   backoff_max => maps:get(backoff_max, Provider),
                   backoff_type => maps:get(backoff_type, Provider)},
    #{id => {oidcc_provider_configuration, Name},
      start => {oidcc_provider_configuration_worker, start_link,
                [WorkerOpts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [oidcc_provider_configuration_worker]}.

valid_issuer(Issuer) when is_binary(Issuer), byte_size(Issuer) > 0 ->
    try uri_string:parse(Issuer) of
        #{scheme := <<"https">>, host := Host} = Uri
          when is_binary(Host), byte_size(Host) > 0 ->
            not maps:is_key(userinfo, Uri) andalso
            not maps:is_key(query, Uri) andalso
            not maps:is_key(fragment, Uri);
        _ -> false
    catch
        _:_ -> false
    end;
valid_issuer(_Issuer) -> false.

contains_secret_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          sensitive_key(Key) orelse contains_secret_key(Value)
      end, maps:to_list(Map));
contains_secret_key(List) when is_list(List) ->
    contains_secret_list(List);
contains_secret_key(Tuple) when is_tuple(Tuple) ->
    contains_secret_key(tuple_to_list(Tuple));
contains_secret_key(_Value) -> false.

contains_secret_list([]) -> false;
contains_secret_list([Head | Tail]) ->
    contains_secret_key(Head) orelse contains_secret_list(Tail);
contains_secret_list(ImproperTail) ->
    contains_secret_key(ImproperTail).

sensitive_key(Key) ->
    case normalized_key(Key) of
        undefined -> false;
        Normalized ->
            lists:member(Normalized,
                         [<<"authorization">>, <<"api_key">>, <<"apikey">>,
                          <<"client_secret">>, <<"access_token">>,
                          <<"refresh_token">>, <<"id_token">>, <<"token">>,
                          <<"password">>, <<"private_key">>, <<"cookie">>])
    end.

normalized_key(Key) when is_atom(Key) ->
    normalized_key(atom_to_binary(Key, utf8));
normalized_key(Key) when is_binary(Key) ->
    try
        Lower = string:lowercase(Key),
        binary:replace(Lower, <<"-">>, <<"_">>, [global])
    catch
        _:_ -> undefined
    end;
normalized_key(Key) when is_list(Key) ->
    try normalized_key(unicode:characters_to_binary(Key))
    catch _:_ -> undefined
    end;
normalized_key(_) -> undefined.

unknown_keys(Map, Allowed) ->
    [Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)].
