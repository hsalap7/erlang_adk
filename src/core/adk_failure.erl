%% @doc Structural, secret-free failure values for public runtime boundaries.
%%
%% Failure reasons and stacktraces are attacker/provider controlled and may
%% contain credentials, request bodies, or arbitrary user data.  This module
%% deliberately classifies those terms instead of redacting selected keys.
%% Only bounded component/operation/class/status/correlation metadata survives.
-module(adk_failure).

-export([exception/4, external/3, sanitize/3,
         callback_value/3, model_response/3,
         log_metadata/3, is_failure/1]).

-define(MAX_CORRELATION_BYTES, 512).
-define(MAX_SCAN_DEPTH, 5).
-define(MAX_MAP_ENTRIES, 32).

-type failure() :: {adk_failure, map()}.
-export_type([failure/0]).

-spec exception(term(), term(), term(), term()) -> failure().
exception(Component, Operation, Class, Reason) ->
    build(Component, Operation, safe_class(Class), Reason).

-spec external(term(), term(), term()) -> failure().
external(Component, Operation, Reason) ->
    build(Component, Operation, external, Reason).

-spec sanitize(term(), term(), term()) -> failure().
sanitize(_Component, _Operation, Failure = {adk_failure, Metadata})
  when is_map(Metadata) ->
    Failure;
sanitize(Component, Operation, Reason) ->
    external(Component, Operation, Reason).

%% Keep the conventional error wrapper used by model/tool plugin hooks while
%% replacing its payload. Successful values are intentionally not rewritten.
-spec callback_value(term(), term(), term()) -> term().
callback_value(Component, Operation, {error, Reason}) ->
    {error, sanitize(Component, Operation, Reason)};
callback_value(Component, Operation, {failed, Reason}) ->
    {failed, sanitize(Component, Operation, Reason)};
callback_value(Component, Operation, {'EXIT', Reason}) ->
    {'EXIT', sanitize(Component, Operation, Reason)};
callback_value(_Component, _Operation,
               Failure = {adk_failure, Metadata}) when is_map(Metadata) ->
    Failure;
callback_value(Component, Operation, Reason) ->
    sanitize(Component, Operation, Reason).

%% JSON-safe error body suitable for a tool response that will be shown to a
%% model. It never contains the original reason or an HTTP response body.
-spec model_response(term(), term(), term()) -> map().
model_response(Component, Operation, Reason) ->
    {adk_failure, Metadata} = sanitize(Component, Operation, Reason),
    #{<<"failure">> => json_metadata(Metadata)}.

-spec log_metadata(term(), term(), term()) -> map().
log_metadata(Component, Operation, Failure) ->
    {adk_failure, Metadata} = sanitize(Component, Operation, Failure),
    Metadata.

-spec is_failure(term()) -> boolean().
is_failure({adk_failure, Metadata}) when is_map(Metadata) -> true;
is_failure(_) -> false.

build(Component, Operation, Class, Reason) ->
    Base = #{component => safe_tag(Component, unknown_component),
             operation => safe_tag(Operation, unknown_operation),
             class => Class,
             reason => reason_tag(Reason)},
    WithStatus = case find_status(Reason, 0) of
        undefined -> Base;
        Status -> Base#{status => Status}
    end,
    Correlations = find_correlations(Reason, 0, #{}),
    Metadata = case map_size(Correlations) of
        0 -> WithStatus;
        _ -> WithStatus#{correlation => Correlations}
    end,
    {adk_failure, Metadata}.

safe_class(error) -> error;
safe_class(exit) -> exit;
safe_class(throw) -> throw;
safe_class(_) -> exception.

safe_tag(Tag, _Default) when is_atom(Tag) -> Tag;
safe_tag(_Tag, Default) -> Default.

reason_tag({adk_failure, Metadata}) when is_map(Metadata) ->
    maps:get(reason, Metadata, failure);
reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(Binary) when is_binary(Binary) -> binary_failure;
reason_tag(List) when is_list(List) -> list_failure;
reason_tag(Map) when is_map(Map) -> map_failure;
reason_tag(Tuple) when is_tuple(Tuple) -> tuple_failure;
reason_tag(Integer) when is_integer(Integer) -> integer_failure;
reason_tag(Float) when is_float(Float) -> float_failure;
reason_tag(Pid) when is_pid(Pid) -> process_failure;
reason_tag(Ref) when is_reference(Ref) -> reference_failure;
reason_tag(Port) when is_port(Port) -> port_failure;
reason_tag(Fun) when is_function(Fun) -> function_failure;
reason_tag(_) -> unknown_failure.

find_status(_Term, Depth) when Depth >= ?MAX_SCAN_DEPTH -> undefined;
find_status(Map, Depth) when is_map(Map) ->
    case status_from_map(Map) of
        undefined ->
            find_status_map(
              maps:iterator(Map), Depth + 1, ?MAX_MAP_ENTRIES);
        Status -> Status
    end;
find_status(Tuple, Depth) when is_tuple(Tuple) ->
    Values = tuple_to_list(Tuple),
    case Values of
        [Tag, Status | _]
          when (Tag =:= http_error orelse Tag =:= http_status orelse
                Tag =:= http_failure orelse Tag =:= status),
               is_integer(Status), Status >= 100, Status =< 599 ->
            Status;
        _ -> find_status_list(Values, Depth + 1)
    end;
find_status(List, Depth) when is_list(List) ->
    find_status_list_bounded(List, Depth + 1, 32);
find_status(_, _) -> undefined.

status_from_map(Map) ->
    status_from_keys([status, status_code, http_status,
                      <<"status">>, <<"status_code">>,
                      <<"http_status">>], Map).

status_from_keys([], _Map) -> undefined;
status_from_keys([Key | Rest], Map) ->
    case maps:find(Key, Map) of
        {ok, Status} when is_integer(Status), Status >= 100, Status =< 599 ->
            Status;
        _ -> status_from_keys(Rest, Map)
    end.

find_status_list([], _Depth) -> undefined;
find_status_list([Value | Rest], Depth) ->
    case find_status(Value, Depth) of
        undefined -> find_status_list(Rest, Depth);
        Status -> Status
    end.

find_status_list_bounded(_List, _Depth, 0) -> undefined;
find_status_list_bounded([], _Depth, _Remaining) -> undefined;
find_status_list_bounded([Value | Rest], Depth, Remaining) ->
    case find_status(Value, Depth) of
        undefined -> find_status_list_bounded(Rest, Depth, Remaining - 1);
        Status -> Status
    end;
find_status_list_bounded(_Improper, _Depth, _Remaining) -> undefined.

find_status_map(_Iterator, _Depth, 0) -> undefined;
find_status_map(Iterator0, Depth, Remaining) ->
    case maps:next(Iterator0) of
        none -> undefined;
        {_Key, Value, Iterator} ->
            case find_status(Value, Depth) of
                undefined -> find_status_map(
                               Iterator, Depth, Remaining - 1);
                Status -> Status
            end
    end.

find_correlations(_Term, Depth, Acc) when Depth >= ?MAX_SCAN_DEPTH -> Acc;
find_correlations(Map, Depth, Acc0) when is_map(Map) ->
    find_correlations_map(
      maps:iterator(Map), Depth + 1, Acc0, ?MAX_MAP_ENTRIES);
find_correlations(Tuple, Depth, Acc) when is_tuple(Tuple) ->
    find_correlations_list(tuple_to_list(Tuple), Depth + 1, Acc, 32);
find_correlations(List, Depth, Acc) when is_list(List) ->
    find_correlations_list(List, Depth + 1, Acc, 32);
find_correlations(_, _, Acc) -> Acc.

find_correlations_list(_Values, _Depth, Acc, 0) -> Acc;
find_correlations_list([], _Depth, Acc, _Remaining) -> Acc;
find_correlations_list([Value | Rest], Depth, Acc0, Remaining) ->
    Acc = find_correlations(Value, Depth, Acc0),
    find_correlations_list(Rest, Depth, Acc, Remaining - 1);
find_correlations_list(_Improper, _Depth, Acc, _Remaining) -> Acc.

find_correlations_map(_Iterator, _Depth, Acc, 0) -> Acc;
find_correlations_map(Iterator0, Depth, Acc0, Remaining) ->
    case maps:next(Iterator0) of
        none -> Acc0;
        {Key, Value, Iterator} ->
            Acc = case correlation_key(Key) of
                undefined -> find_correlations(Value, Depth, Acc0);
                CorrelationKey ->
                    case correlation_fingerprint(Value) of
                        undefined -> Acc0;
                        Fingerprint -> Acc0#{CorrelationKey => Fingerprint}
                    end
            end,
            find_correlations_map(
              Iterator, Depth, Acc, Remaining - 1)
    end.

correlation_key(invocation_id) -> invocation_id;
correlation_key(run_id) -> run_id;
correlation_key(call_id) -> call_id;
correlation_key(task_ref) -> task_ref;
correlation_key(request_id) -> request_id;
correlation_key(correlation_id) -> correlation_id;
correlation_key(<<"invocation_id">>) -> invocation_id;
correlation_key(<<"run_id">>) -> run_id;
correlation_key(<<"call_id">>) -> call_id;
correlation_key(<<"task_ref">>) -> task_ref;
correlation_key(<<"request_id">>) -> request_id;
correlation_key(<<"correlation_id">>) -> correlation_id;
correlation_key(_) -> undefined.

correlation_fingerprint(Value) when is_binary(Value),
                                    byte_size(Value) > 0,
                                    byte_size(Value) =< ?MAX_CORRELATION_BYTES ->
    fingerprint(Value);
correlation_fingerprint(Value) when is_atom(Value); is_integer(Value) ->
    fingerprint(term_to_binary(Value));
correlation_fingerprint(_) -> undefined.

fingerprint(Binary) ->
    Hash = crypto:hash(sha256, Binary),
    Prefix = binary:part(Hash, 0, 12),
    binary:encode_hex(Prefix, lowercase).

json_metadata(Metadata) ->
    maps:from_list(
      [{atom_to_binary(Key, utf8), json_value(Value)}
       || {Key, Value} <- maps:to_list(Metadata)]).

json_value(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
json_value(Value) when is_map(Value) -> json_metadata(Value);
json_value(Value) -> Value.
