-module(adk_artifact_stream_test).

-include_lib("eunit/include/eunit.hrl").

-define(SCOPE, {session, <<"app">>, <<"user">>, <<"session">>}).

upload_acknowledges_and_download_backpressures_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, Service} = start(Store),
    try
        {ok, Upload, #{credit := #{messages := 1, bytes := 2}}} =
            adk_artifact_stream:open_upload(
              {adk_artifact_gcs, Service}, ?SCOPE, <<"stream.bin">>, #{},
              #{chunk_bytes => 2, timeout_ms => 1000}),
        {ok, #{ack := 1, credit := #{messages := 1, bytes := 2}}} =
            adk_artifact_stream:send_chunk(Upload, 1, <<"ab">>),
        ?assertEqual({error, sequence_mismatch},
                     adk_artifact_stream:send_chunk(Upload, 3, <<"xx">>)),
        {ok, #{ack := 2}} =
            adk_artifact_stream:send_chunk(Upload, 2, <<"cd">>),
        {ok, #{ack := 3}} =
            adk_artifact_stream:send_chunk(Upload, 3, <<"ef">>),
        {ok, #{status := committing}} =
            adk_artifact_stream:finish_upload(Upload),
        {ok, {done, #{version := 1}}} =
            adk_artifact_stream:recv(Upload, 1000),

        {ok, Download, #{size := 6}} =
            adk_artifact_stream:open_download(
              {adk_artifact_gcs, Service}, ?SCOPE, <<"stream.bin">>, latest,
              #{chunk_bytes => 2, timeout_ms => 1000}),
        ok = adk_artifact_stream:credit(Download, 2, 4),
        {ok, {chunk, 1, 0, <<"ab">>}} =
            adk_artifact_stream:recv(Download, 1000),
        %% A second granted credit cannot be consumed until the first chunk is
        %% explicitly acknowledged.
        ?assertEqual({error, timeout}, adk_artifact_stream:recv(Download, 20)),
        ?assertEqual({error, ack_mismatch},
                     adk_artifact_stream:ack(Download, 99)),
        ok = adk_artifact_stream:ack(Download, 1),
        {ok, {chunk, 2, 2, <<"cd">>}} =
            adk_artifact_stream:recv(Download, 1000),
        ok = adk_artifact_stream:ack(Download, 2),
        ok = adk_artifact_stream:credit(Download, 1, 2),
        {ok, {chunk, 3, 4, <<"ef">>}} =
            adk_artifact_stream:recv(Download, 1000),
        ok = adk_artifact_stream:ack(Download, 3),
        {ok, {done, #{size := 6}}} =
            adk_artifact_stream:recv(Download, 1000)
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

deadline_fires_for_slow_consumer_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, Service} = start(Store),
    try
        {ok, _} = adk_artifact_gcs:put(
                    Service, ?SCOPE, <<"slow">>, <<"abcd">>, #{}),
        {ok, Download, _} = adk_artifact_stream:open_download(
                              {adk_artifact_gcs, Service}, ?SCOPE, <<"slow">>,
                              latest, #{timeout_ms => 40}),
        {ok, {error, timeout}} = adk_artifact_stream:recv(Download, 1000)
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

cancellation_stops_blocked_publication_test() ->
    Store = adk_artifact_gcs_test_transport:new(
              #{controller => self(),
                block => #{operation => put_if_absent,
                           suffix => <<".meta">>}}),
    {ok, Service} = start(Store),
    try
        {ok, Upload, _} = adk_artifact_stream:open_upload(
                            {adk_artifact_gcs, Service}, ?SCOPE,
                            <<"cancelled">>, #{}, #{timeout_ms => 1000}),
        {ok, _} = adk_artifact_stream:send_chunk(Upload, 1, <<"ab">>),
        {ok, #{status := committing}} =
            adk_artifact_stream:finish_upload(Upload),
        Blocked = receive
            {gcs_fake_blocked, Pid, put_if_absent, _Object} -> Pid
        after 1000 -> timeout
        end,
        ?assert(is_pid(Blocked)),
        Monitor = erlang:monitor(process, Blocked),
        ok = adk_artifact_stream:cancel(Upload, user_cancelled),
        receive {'DOWN', Monitor, process, Blocked, _} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual({error, not_found},
                     adk_artifact_gcs:get(
                       Service, ?SCOPE, <<"cancelled">>, latest))
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

owner_death_terminates_stream_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, Service} = start(Store),
    try
        Parent = self(),
        Owner = spawn(fun() ->
            {ok, Stream, _} = adk_artifact_stream:open_upload(
                                {adk_artifact_gcs, Service}, ?SCOPE,
                                <<"orphan">>, #{}, #{timeout_ms => 1000}),
            Parent ! {owner_stream, self(), Stream},
            receive stop -> ok end
        end),
        Stream = receive {owner_stream, Owner, Value} -> Value after 1000 -> timeout end,
        {adk_artifact_stream, StreamPid, _Ref} = Stream,
        Monitor = erlang:monitor(process, StreamPid),
        exit(Owner, kill),
        receive {'DOWN', Monitor, process, StreamPid, _} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual({error, not_found},
                     adk_artifact_gcs:get(Service, ?SCOPE, <<"orphan">>, latest))
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

start(Store) ->
    adk_artifact_gcs:start_link(
      #{bucket => <<"adk-test-bucket">>,
        project => <<"adk-test-project">>,
        credential => {adk_artifact_gcs_test_credential,
                       #{token => <<"unused-by-fake">>}},
        transport => {adk_artifact_gcs_test_transport, Store},
        max_artifact_bytes => 1024,
        max_response_bytes => 1024,
        stream => #{chunk_bytes => 2, max_credit_messages => 2,
                    max_credit_bytes => 4, timeout_ms => 1000}}).
