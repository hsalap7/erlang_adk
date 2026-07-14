%% @doc Internal contracts for human confirmation of tool side effects.
%%
%% Confirmation metadata is evaluated only after a model call has passed its
%% JSON schema and Runner runtime-policy checks.  It is never part of the
%% provider-visible tool declaration and this module never executes a tool.
-module(adk_tool_confirmation).

-export([module_requirement/3, resolved_requirement/1,
         resolved_requirement/3,
         is_required/1, action_id/4, summary/2,
         rejection_response/1, valid_details/1, matches_action/5]).

-define(MAX_HINT_BYTES, 4096).

-type requirement() :: none | #{required := true, hint => binary()}.
-export_type([requirement/0]).

%% @doc Evaluate the optional module callbacks.  The argument-aware callback
%% takes precedence over the static callback when both are exported.
-spec module_requirement(module(), map(), map()) ->
    {ok, requirement()} | {error, term()}.
module_requirement(Module, Args, Context)
  when is_atom(Module), is_map(Args), is_map(Context) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            evaluate_module_requirement(Module, Args, Context);
        _ ->
            {error, {tool_module_unavailable, Module}}
    end;
module_requirement(_Module, _Args, _Context) ->
    {error, invalid_tool_confirmation_callback}.

evaluate_module_requirement(Module, Args, Context) ->
    try
        Value = case erlang:function_exported(
                           Module, require_confirmation, 2) of
            true -> Module:require_confirmation(Args, Context);
            false ->
                case erlang:function_exported(
                           Module, require_confirmation, 0) of
                    true -> Module:require_confirmation();
                    false -> false
                end
        end,
        normalize_requirement(Value)
    catch
        Class:Reason:_Stack ->
            {error, adk_failure:exception(
                      tool_confirmation, evaluate, Class, Reason)}
    end.

%% @doc Read already validated, internal metadata from a resolved toolset call.
-spec resolved_requirement(map()) ->
    {ok, requirement()} | {error, term()}.
resolved_requirement(ResolvedCall) when is_map(ResolvedCall) ->
    normalize_requirement(maps:get(confirmation, ResolvedCall, false));
resolved_requirement(_ResolvedCall) ->
    {error, invalid_tool_confirmation_metadata}.

%% @doc Resolve confirmation for a dynamic call. Opaque execute closures own
%% their internal confirmation metadata. A resolved local module must also
%% honour the module's declaration, so a toolset alias cannot weaken a module
%% which requires approval. Either declaration requiring confirmation wins;
%% either declaration failing validation fails closed.
-spec resolved_requirement(map(), map(), map()) ->
    {ok, requirement()} | {error, term()}.
resolved_requirement(ResolvedCall, Args, Context)
  when is_map(ResolvedCall), is_map(Args), is_map(Context) ->
    Metadata = resolved_requirement(ResolvedCall),
    case maps:find(module, ResolvedCall) of
        {ok, Module} when is_atom(Module) ->
            merge_requirements(
              Metadata, module_requirement(Module, Args, Context));
        error ->
            Metadata;
        _ ->
            {error, invalid_resolved_tool_call}
    end;
resolved_requirement(_ResolvedCall, _Args, _Context) ->
    {error, invalid_tool_confirmation_metadata}.

merge_requirements({error, _} = Error, _Module) -> Error;
merge_requirements(_Metadata, {error, _} = Error) -> Error;
merge_requirements({ok, none}, {ok, Requirement}) -> {ok, Requirement};
merge_requirements({ok, Requirement}, {ok, none}) -> {ok, Requirement};
merge_requirements({ok, First}, {ok, Second}) ->
    {ok, merge_required_maps(First, Second)}.

merge_required_maps(#{required := true} = First,
                    #{required := true} = Second) ->
    case {maps:find(hint, First), maps:find(hint, Second)} of
        {{ok, _Hint}, _} -> First;
        {error, {ok, Hint}} -> First#{hint => Hint};
        {error, error} -> First
    end.

normalize_requirement(false) -> {ok, none};
normalize_requirement(true) -> {ok, #{required => true}};
normalize_requirement(Requirement) when is_map(Requirement) ->
    normalize_requirement_map(Requirement);
normalize_requirement(_Requirement) ->
    {error, invalid_tool_confirmation_metadata}.

normalize_requirement_map(Requirement) ->
    AtomRequired = maps:find(required, Requirement),
    BinaryRequired = maps:find(<<"required">>, Requirement),
    AtomHint = maps:find(hint, Requirement),
    BinaryHint = maps:find(<<"hint">>, Requirement),
    Unknown = maps:without(
                [required, <<"required">>, hint, <<"hint">>],
                Requirement),
    case duplicate_key(AtomRequired, BinaryRequired) orelse
         duplicate_key(AtomHint, BinaryHint) orelse
         map_size(Unknown) =/= 0 of
        true ->
            {error, invalid_tool_confirmation_metadata};
        false ->
            Required = selected_value(
                         AtomRequired, BinaryRequired, true),
            Hint = selected_value(AtomHint, BinaryHint, undefined),
            canonical_requirement(Required, Hint)
    end.

duplicate_key({ok, _}, {ok, _}) -> true;
duplicate_key(_Atom, _Binary) -> false.

selected_value({ok, Value}, error, _Default) -> Value;
selected_value(error, {ok, Value}, _Default) -> Value;
selected_value(error, error, Default) -> Default.

canonical_requirement(false, Hint) ->
    case valid_hint(Hint) of
        true -> {ok, none};
        false -> {error, invalid_tool_confirmation_metadata}
    end;
canonical_requirement(true, Hint) ->
    case valid_hint(Hint) of
        true when Hint =:= undefined -> {ok, #{required => true}};
        true -> {ok, #{required => true, hint => Hint}};
        false -> {error, invalid_tool_confirmation_metadata}
    end;
canonical_requirement(_Required, _Hint) ->
    {error, invalid_tool_confirmation_metadata}.

valid_hint(undefined) -> true;
valid_hint(Hint) when is_binary(Hint),
                      byte_size(Hint) =< ?MAX_HINT_BYTES ->
    try unicode:characters_to_binary(Hint, utf8, utf8) of
        Hint -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_hint(_Hint) -> false.

-spec is_required(requirement() | map() | term()) -> boolean().
is_required(#{required := true}) -> true;
is_required(_) -> false.

%% @doc Stable opaque identity for one exact model call.  The digest includes
%% the invocation, correlation ID, name, and canonical arguments, but none of
%% those raw values are embedded in the public identifier.
-spec action_id(binary(), map(), binary(), term()) -> binary().
action_id(Name, Args, InvocationId, CallId)
  when is_binary(Name), is_map(Args), is_binary(InvocationId) ->
    CanonicalArgs = case adk_json:normalize(Args) of
        {ok, JsonArgs} when is_map(JsonArgs) -> JsonArgs;
        _ -> #{}
    end,
    CanonicalCallId = case CallId of
        null -> undefined;
        _ -> CallId
    end,
    Digest = crypto:hash(
               sha256,
               term_to_binary(
                 {InvocationId, Name, CanonicalCallId, CanonicalArgs},
                 [deterministic])),
    <<"tool-confirm-", (binary:encode_hex(Digest, lowercase))/binary>>.

-spec summary(binary(), requirement()) -> binary().
summary(_Name, #{hint := Hint}) -> Hint;
summary(Name, _Requirement) ->
    <<"Approve execution of tool ", Name/binary, ".">>.

-spec rejection_response(binary()) -> map().
rejection_response(ActionId) ->
    #{<<"success">> => false,
      <<"error">> =>
          #{<<"kind">> => <<"tool_confirmation_rejected">>,
            <<"action_id">> => ActionId}}.

-spec valid_details(term()) -> boolean().
valid_details(#{<<"type">> := <<"tool_confirmation">>,
                <<"action_id">> := ActionId} = Details)
  when is_binary(ActionId) ->
    Unknown = maps:without(
                [<<"type">>, <<"action_id">>, <<"hint">>], Details),
    map_size(Unknown) =:= 0 andalso
    byte_size(ActionId) =:= byte_size(<<"tool-confirm-">>) + 64 andalso
    valid_action_id(ActionId) andalso
    valid_hint(maps:get(<<"hint">>, Details, undefined));
valid_details(_Details) -> false.

valid_action_id(<<"tool-confirm-", Hex/binary>>) ->
    byte_size(Hex) =:= 64 andalso valid_lower_hex(Hex);
valid_action_id(_ActionId) -> false.

valid_lower_hex(<<>>) -> true;
valid_lower_hex(<<Char, Rest/binary>>)
  when (Char >= $0 andalso Char =< $9) orelse
       (Char >= $a andalso Char =< $f) ->
    valid_lower_hex(Rest);
valid_lower_hex(_Invalid) -> false.

-spec matches_action(map(), binary(), map(), binary(), term()) -> boolean().
matches_action(Details, Name, Args, InvocationId, CallId) ->
    valid_details(Details) andalso
    maps:get(<<"action_id">>, Details) =:=
        action_id(Name, Args, InvocationId, CallId).
