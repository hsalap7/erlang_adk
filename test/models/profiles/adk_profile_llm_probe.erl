-module(adk_profile_llm_probe).

-behaviour(adk_llm).

-export([generate/3, stream/4, validate_config/1,
         profile_request_option_allowlist/0]).

%% Agent execution materializes the compiled system instruction into the
%% provider request. A custom profile adapter must explicitly accept that
%% provider-facing option in addition to its fixture controls.
profile_request_option_allowlist() ->
    [test_pid, temperature, instructions,
     '$adk_inherited_global_instruction'].

generate(Config, _Memory, _Tools) ->
    maps:get(test_pid, Config) ! {profile_probe_config, Config},
    {ok, <<"profile response">>}.

stream(Config, _Memory, _Tools, Callback) ->
    maps:get(test_pid, Config) ! {profile_probe_config, Config},
    Callback(<<"profile stream">>).

validate_config(Config) ->
    Required = [provider, model, base_url, api_key, test_pid],
    case lists:all(fun(Key) -> maps:is_key(Key, Config) end, Required) of
        true -> ok;
        false -> {error, incomplete_profile_config}
    end.
