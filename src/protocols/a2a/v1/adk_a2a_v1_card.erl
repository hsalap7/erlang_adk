%% @doc Agent Card construction and selection for the A2A 1.0 JSON-RPC binding.
-module(adk_a2a_v1_card).

-export([new/1, validate/1, json/1, jsonrpc_interface/1,
         required_extensions/1]).

-spec new(map()) -> {ok, map()} | {error, term()}.
new(Config) when is_map(Config) ->
    Url = maps:get(url, Config, undefined),
    Card0 = #{
      <<"name">> => maps:get(name, Config, <<"Erlang ADK agent">>),
      <<"description">> => maps:get(
                              description, Config,
                              <<"An OTP-native A2A agent">>),
      <<"supportedInterfaces">> => [
        #{<<"url">> => Url,
          <<"protocolBinding">> => <<"JSONRPC">>,
          <<"protocolVersion">> => <<"1.0">>}
      ],
      <<"version">> => maps:get(version, Config, application_version()),
      <<"capabilities">> => #{
        <<"streaming">> => maps:get(streaming, Config, true),
        <<"pushNotifications">> => false,
        <<"extendedAgentCard">> => false,
        <<"extensions">> => maps:get(extensions, Config, [])
      },
      <<"defaultInputModes">> => maps:get(
                                    default_input_modes, Config,
                                    [<<"text/plain">>,
                                     <<"application/json">>]),
      <<"defaultOutputModes">> => maps:get(
                                     default_output_modes, Config,
                                     [<<"text/plain">>,
                                      <<"application/json">>]),
      <<"skills">> => maps:get(
                         skills, Config,
                         [#{<<"id">> => <<"general">>,
                            <<"name">> => <<"General agent">>,
                            <<"description">> =>
                                <<"Process an A2A message">>,
                            <<"tags">> => [<<"agent">>]}])
    },
    Card1 = copy_optional(
              [{provider, <<"provider">>},
               {documentation_url, <<"documentationUrl">>},
               {security_schemes, <<"securitySchemes">>},
               {security_requirements, <<"securityRequirements">>},
               {icon_url, <<"iconUrl">>}], Config, Card0),
    validate(Card1);
new(_) ->
    {error, invalid_agent_card_config}.

-spec validate(term()) -> {ok, map()} | {error, term()}.
validate(Card) ->
    case adk_a2a_v1_codec:validate_agent_card(Card) of
        {ok, SafeCard} ->
            case jsonrpc_interface(SafeCard) of
                {ok, _} -> {ok, SafeCard};
                {error, _} = Error -> Error
            end;
        Error -> Error
    end.

-spec json(map()) -> {ok, binary()} | {error, term()}.
json(Card) ->
    case validate(Card) of
        {ok, SafeCard} ->
            try jsx:encode(SafeCard) of
                Encoded -> {ok, Encoded}
            catch
                _:_ -> {error, invalid_agent_card_json}
            end;
        Error -> Error
    end.

-spec jsonrpc_interface(map()) -> {ok, map()} | {error, term()}.
jsonrpc_interface(#{<<"supportedInterfaces">> := Interfaces})
  when is_list(Interfaces) ->
    case lists:dropwhile(
           fun(Interface) ->
               maps:get(<<"protocolBinding">>, Interface, undefined)
                   =/= <<"JSONRPC">>
               orelse maps:get(<<"protocolVersion">>, Interface, undefined)
                   =/= <<"1.0">>
           end, Interfaces) of
        [Interface | _] -> {ok, Interface};
        [] -> {error, no_supported_a2a_1_0_jsonrpc_interface}
    end;
jsonrpc_interface(_) ->
    {error, no_supported_a2a_1_0_jsonrpc_interface}.

%% @doc Return the bounded set of extension URIs clients must acknowledge.
-spec required_extensions(map()) -> [binary()].
required_extensions(Card) when is_map(Card) ->
    Capabilities = maps:get(<<"capabilities">>, Card, #{}),
    Extensions = maps:get(<<"extensions">>, Capabilities, []),
    [maps:get(<<"uri">>, Extension)
     || Extension <- Extensions,
        maps:get(<<"required">>, Extension, false) =:= true];
required_extensions(_) ->
    [].

application_version() ->
    _ = application:load(erlang_adk),
    case application:get_key(erlang_adk, vsn) of
        {ok, Version} when is_list(Version) ->
            unicode:characters_to_binary(Version);
        {ok, Version} when is_binary(Version) -> Version;
        _ -> <<"unknown">>
    end.

copy_optional([], _Config, Card) -> Card;
copy_optional([{ConfigKey, JsonKey} | Rest], Config, Card0) ->
    Card1 = case maps:find(ConfigKey, Config) of
        {ok, Value} -> Card0#{JsonKey => Value};
        error -> Card0
    end,
    copy_optional(Rest, Config, Card1).
