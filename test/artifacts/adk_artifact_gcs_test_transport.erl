%% Deterministic shared object store and HTTP recorder for GCS adapter tests.
-module(adk_artifact_gcs_test_transport).
-behaviour(adk_artifact_gcs_transport).

-export([new/0, new/1, objects/1,
         put_if_absent/4, get/3, get_range/5, list/5, delete/3,
         request/2]).

new() -> new(#{}).

new(Options) when is_map(Options) ->
    Table = ets:new(?MODULE, [ordered_set, public,
                              {read_concurrency, true},
                              {write_concurrency, true}]),
    Options#{table => Table, controller => maps:get(controller, Options,
                                                     self())}.

objects(#{table := Table}) ->
    lists:sort([{Object, Data} || {{object, Object}, Data} <- ets:tab2list(Table)]).

put_if_absent(Handle, Object, Data, Context) ->
    case before_operation(Handle, put_if_absent, Object, Context) of
        ok ->
            case configured_failure(Handle) of
                none ->
                    case ets:insert_new(maps:get(table, Handle),
                                        {{object, Object}, Data}) of
                        true -> ok;
                        false -> {error, exists}
                    end;
                Failure -> {error, Failure}
            end;
        {error, _} = Error -> Error
    end.

get(Handle, Object, Context) ->
    case before_operation(Handle, get, Object, Context) of
        ok ->
            case configured_failure(Handle) of
                none -> lookup(Handle, Object);
                Failure -> {error, Failure}
            end;
        {error, _} = Error -> Error
    end.

get_range(Handle, Object, Offset, Length, Context) ->
    case before_operation(Handle, get_range, Object, Context) of
        ok ->
            case lookup(Handle, Object) of
                {ok, Data} when Offset + Length =< byte_size(Data) ->
                    {ok, binary:part(Data, Offset, Length)};
                {ok, _Data} -> {error, invalid_range};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

list(Handle, Prefix, Cursor, Limit, Context) ->
    case before_operation(Handle, list, Prefix, Context) of
        ok ->
            Objects0 = [Object || {{object, Object}, _Data}
                                      <- ets:tab2list(maps:get(table, Handle)),
                                  has_prefix(Object, Prefix)],
            Objects = lists:sort(Objects0),
            Remaining = case Cursor of
                undefined -> Objects;
                _ -> lists:dropwhile(fun(Object) -> Object =< Cursor end,
                                     Objects)
            end,
            Candidate = lists:sublist(Remaining, Limit + 1),
            More = length(Candidate) > Limit,
            Items = lists:sublist(Candidate, Limit),
            Next = case More of true -> lists:last(Items); false -> undefined end,
            {ok, #{items => Items, next_cursor => Next}};
        {error, _} = Error -> Error
    end.

delete(Handle, Object, Context) ->
    case before_operation(Handle, delete, Object, Context) of
        ok ->
            case ets:take(maps:get(table, Handle), {object, Object}) of
                [] -> {error, not_found};
                [_] -> ok
            end;
        {error, _} = Error -> Error
    end.

%% Implements adk_openapi_http_transport for request construction tests.
request(#{controller := Controller, response := raise}, Request) ->
    Controller ! {gcs_http_request, Request},
    erlang:error(deliberate_http_transport_failure);
request(#{controller := Controller, response := Response}, Request) ->
    Controller ! {gcs_http_request, Request},
    Response.

lookup(Handle, Object) ->
    case ets:lookup(maps:get(table, Handle), {object, Object}) of
        [{{object, Object}, Data}] -> {ok, Data};
        [] -> {error, not_found}
    end.

configured_failure(Handle) -> maps:get(fail, Handle, none).

before_operation(Handle, Operation, Object, Context) ->
    case maps:get(block, Handle, none) of
        #{operation := Operation, suffix := Suffix} ->
            case has_suffix(Object, Suffix) of
                true -> wait_for_release(Handle, Operation, Object, Context);
                false -> maybe_delay(Handle, Context)
            end;
        _ -> maybe_delay(Handle, Context)
    end.

wait_for_release(Handle, Operation, Object, Context) ->
    Controller = maps:get(controller, Handle),
    Controller ! {gcs_fake_blocked, self(), Operation, Object},
    Deadline = maps:get(deadline, Context),
    receive
        {gcs_fake_release, Pid} when Pid =:= self() -> ok
    after remaining(Deadline) ->
        {error, timeout}
    end.

maybe_delay(Handle, Context) ->
    case maps:get(delay_ms, Handle, 0) of
        Delay when is_integer(Delay), Delay > 0 ->
            Left = remaining(maps:get(deadline, Context)),
            case Delay < Left of
                true -> timer:sleep(Delay), ok;
                false -> timer:sleep(Left), {error, timeout}
            end;
        _ -> ok
    end.

has_prefix(Binary, Prefix) when byte_size(Binary) >= byte_size(Prefix) ->
    binary:part(Binary, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_Binary, _Prefix) -> false.

has_suffix(Binary, Suffix) when byte_size(Binary) >= byte_size(Suffix) ->
    binary:part(Binary, byte_size(Binary) - byte_size(Suffix),
                byte_size(Suffix)) =:= Suffix;
has_suffix(_Binary, _Suffix) -> false.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
