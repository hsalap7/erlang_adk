-module(adk_bounded_file_test).

-include_lib("eunit/include/eunit.hrl").

bounded_regular_file_reader_test() ->
    Path = temp_path("bounded-file"),
    try
        ok = file:write_file(Path, <<"12345678">>),
        ?assertEqual({ok, <<"12345678">>},
                     adk_bounded_file:read(Path, 8)),
        ?assertEqual({error, file_too_large},
                     adk_bounded_file:read(Path, 7))
    after
        _ = file:delete(Path)
    end.

sparse_oversized_file_is_rejected_from_metadata_test() ->
    Path = temp_path("bounded-sparse"),
    try
        {ok, IoDevice} = file:open(Path, [write, binary, raw, exclusive]),
        try
            {ok, _} = file:position(IoDevice, {bof, 64 * 1024 * 1024}),
            ok = file:write(IoDevice, <<0>>)
        after
            ok = file:close(IoDevice)
        end,
        ?assertEqual({error, file_too_large},
                     adk_bounded_file:read(Path, 1024 * 1024)),
        ?assertEqual({error, file_too_large},
                     adk_agent_config:load_file(Path))
    after
        _ = file:delete(Path)
    end.

non_regular_inputs_are_rejected_test() ->
    Directory = filename:dirname(temp_path("bounded-directory")),
    ?assertEqual({error, {invalid_file_type, directory}},
                 adk_bounded_file:read(Directory, 1024)).

temp_path(Prefix) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    filename:join(
      Base, Prefix ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))).
