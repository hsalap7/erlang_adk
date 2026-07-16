-module(adk_llm_stream_probe).
-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4, capabilities/0]).

capabilities() ->
    #{multimodal => true,
      content_streaming => true,
      content_schema_version => 1}.

generate(Config, History, Tools) ->
    notify(Config, {probe_generate, self(), History, Tools}),
    {ok, maps:get(response, Config, <<"probe response">>)}.

stream(Config, History, Tools, Callback) ->
    notify(Config, {probe_stream_started, self(), text, History, Tools}),
    emit(Config, maps:get(chunks, Config, [<<"probe stream">>]), Callback).

stream_content(Config, History, Tools, Callback) ->
    notify(Config, {probe_stream_started, self(), content, History, Tools}),
    emit(Config, maps:get(content_chunks, Config, []), Callback).

emit(Config, Chunks, Callback) when is_list(Chunks) ->
    emit(Config, Chunks, Callback, 1),
    maps:get(stream_result, Config, ok).

emit(_Config, [], _Callback, _Index) ->
    ok;
emit(Config, [Chunk | Rest], Callback, Index) ->
    ok = Callback(Chunk),
    maybe_block(Config, Index),
    emit(Config, Rest, Callback, Index + 1).

maybe_block(Config, Index) ->
    case maps:get(block_after_chunk, Config, undefined) of
        Index ->
            Ref = maps:get(stream_ref, Config),
            notify(Config, {probe_stream_blocked, self(), Ref}),
            receive
                {continue_stream, Ref} -> ok
            after maps:get(block_timeout, Config, 5000) ->
                erlang:error(stream_probe_timeout)
            end;
        _ ->
            ok
    end.

notify(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
