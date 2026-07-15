%% @doc Structural validation for provider-emitted tool calls.
%%
%% Provider output is untrusted. Validate the complete batch before persisting
%% an event, invoking callbacks, or starting any tool so a malformed later
%% entry cannot leave an invocation partially executed.
-module(adk_tool_call).

-export([validate/1, validate_list/1]).

-spec validate(term()) -> ok | {error, term()}.
validate({Name, Args}) ->
    validate_fields(Name, Args, undefined, undefined);
validate({Name, Args, ThoughtSignature}) ->
    validate_fields(Name, Args, ThoughtSignature, undefined);
validate({Name, Args, ThoughtSignature, CallId}) ->
    validate_fields(Name, Args, ThoughtSignature, CallId);
validate(_Call) ->
    {error, invalid_shape}.

-spec validate_list(term()) -> ok | {error, term()}.
validate_list(Calls) when is_list(Calls) ->
    validate_list(Calls, 0);
validate_list(_Calls) ->
    {error, invalid_tool_calls}.

validate_list([], _Index) -> ok;
validate_list([Call | Rest], Index) ->
    case validate(Call) of
        ok -> validate_list(Rest, Index + 1);
        {error, Reason} ->
            {error, {invalid_tool_call, Index, Reason}}
    end;
validate_list(_Improper, Index) ->
    {error, {invalid_tool_call, Index, improper_list}}.

validate_fields(Name, Args, ThoughtSignature, CallId) ->
    case valid_name(Name) of
        false -> {error, invalid_name};
        true when not is_map(Args) -> {error, invalid_arguments};
        true ->
            case valid_optional_binary(ThoughtSignature) of
                false -> {error, invalid_thought_signature};
                true ->
                    case valid_optional_binary(CallId) of
                        true -> ok;
                        false -> {error, invalid_call_id}
                    end
            end
    end.

valid_name(Name) when is_binary(Name) -> byte_size(Name) > 0;
valid_name(_Name) -> false.

valid_optional_binary(undefined) -> true;
valid_optional_binary(Value) when is_binary(Value) -> true;
valid_optional_binary(_Value) -> false.
