%% @doc Secret-removing, JSON-safe boundary for session and model context data.
%%
%% Unlike diagnostic redaction, context safety removes secret-bearing fields
%% entirely.  A model must not be told that a credential exists, and a cache
%% key must not depend on its value.  Sensitive maps are pruned before JSON
%% normalization so even a non-JSON credential value can never escape through
%% a validation error.
-module(adk_context_guard).

-include("../include/adk_event.hrl").

-export([sanitize_event/1, sanitize_value/1, sensitive_key/1]).

-type error_reason() ::
    {invalid_event, term()}
    | adk_json:error_reason().
-export_type([error_reason/0]).

%% @doc Convert an event record or persisted event map to its canonical,
%% secret-free JSON representation.
-spec sanitize_event(adk_event:event() | map()) ->
    {ok, map()} | {error, error_reason()}.
sanitize_event(Event = #adk_event{}) ->
    Sanitized = Event#adk_event{
        content = prune_content(Event#adk_event.content),
        actions = prune(Event#adk_event.actions)
    },
    encode_and_check(Sanitized);
sanitize_event(Map) when is_map(Map) ->
    Pruned = prune(Map),
    case adk_event:decode(Pruned) of
        {ok, Event} -> encode_and_check(Event);
        {error, Reason} -> {error, {invalid_event, Reason}}
    end;
sanitize_event(_Other) ->
    {error, {invalid_event, expected_event}}.

%% @doc Normalize an ordinary value to JSON after removing all sensitive map
%% entries.  Binary keys are emitted even if the input used atoms or strings.
-spec sanitize_value(term()) -> {ok, term()} | {error, adk_json:error_reason()}.
sanitize_value(Value) ->
    adk_json:normalize(prune(Value)).

%% @doc Whether a key denotes authentication material. Matching is
%% case-insensitive and separator-insensitive.  Generic keys such as `key' are
%% deliberately retained, while API/private/signing keys are removed.
-spec sensitive_key(term()) -> boolean().
sensitive_key(Key) ->
    case normalized_key(Key) of
        undefined -> false;
        Normalized ->
            lists:member(Normalized, exact_sensitive_keys()) orelse
            contains_any(Normalized,
                         [<<"token">>, <<"credential">>, <<"authorization">>,
                          <<"password">>, <<"passwd">>, <<"secret">>])
    end.

encode_and_check(Event) ->
    case adk_event:encode(Event) of
        {ok, Encoded0} ->
            %% Encoding creates only binary-key maps, but prune once more to
            %% cover aliases accepted by the legacy decoder.
            Encoded = prune(Encoded0),
            case adk_event:decode(Encoded) of
                {ok, _} -> {ok, Encoded};
                {error, Reason} -> {error, {invalid_event, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_event, Reason}}
    end.

prune_content({tool_calls, Calls}) when is_list(Calls) ->
    {tool_calls, [prune_tool_call(Call) || Call <- Calls]};
prune_content({tool_response, Name, Result}) ->
    {tool_response, Name, prune(Result)};
prune_content({tool_response, Name, Result, Signature}) ->
    {tool_response, Name, prune(Result), Signature};
prune_content({tool_response, Name, Result, Signature, CallId}) ->
    {tool_response, Name, prune(Result), Signature, CallId};
prune_content(Other) ->
    Other.

prune_tool_call({Name, Args}) ->
    {Name, prune(Args)};
prune_tool_call({Name, Args, Signature}) ->
    {Name, prune(Args), Signature};
prune_tool_call({Name, Args, Signature, CallId}) ->
    {Name, prune(Args), Signature, CallId};
prune_tool_call(Other) ->
    Other.

prune(Map) when is_map(Map) ->
    maps:from_list(
      [{Key, prune(Value)} || {Key, Value} <- maps:to_list(Map),
                              not sensitive_key(Key)]);
prune(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([prune(Value) || Value <- tuple_to_list(Tuple)]);
prune(List) when is_list(List) ->
    prune_list(List);
prune(Other) ->
    Other.

prune_list([]) -> [];
prune_list([Head | Tail]) -> [prune(Head) | prune_list_tail(Tail)].

prune_list_tail([]) -> [];
prune_list_tail([Head | Tail]) -> [prune(Head) | prune_list_tail(Tail)];
prune_list_tail(Improper) -> prune(Improper).

normalized_key(Key) when is_atom(Key) ->
    normalized_key(atom_to_binary(Key, utf8));
normalized_key(Key) when is_list(Key) ->
    try normalized_key(unicode:characters_to_binary(Key))
    catch _:_ -> undefined
    end;
normalized_key(Key) when is_binary(Key) ->
    try
        Lower = string:lowercase(Key),
        remove_separators(Lower)
    catch
        _:_ -> undefined
    end;
normalized_key(_) ->
    undefined.

remove_separators(Binary) ->
    lists:foldl(
      fun(Separator, Acc) ->
          binary:replace(Acc, Separator, <<>>, [global])
      end,
      Binary,
      [<<"_">>, <<"-">>, <<" ">>, <<".">>, <<":">>]).

contains_any(_Key, []) -> false;
contains_any(Key, [Pattern | Rest]) ->
    case binary:match(Key, Pattern) of
        nomatch -> contains_any(Key, Rest);
        _ -> true
    end.

exact_sensitive_keys() ->
    [<<"apikey">>, <<"privatekey">>, <<"signingkey">>,
     <<"clientassertion">>, <<"bearer">>, <<"cookie">>,
     <<"setcookie">>, <<"otp">>, <<"pin">>].
