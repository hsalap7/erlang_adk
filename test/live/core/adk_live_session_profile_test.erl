-module(adk_live_session_profile_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"live-profile-principal">>).

live_profile_session_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun profile_credential_is_brokered_and_redacted_case/0,
      fun profile_transport_authority_is_rejected_case/0,
      fun handoff_and_policy_share_rejection_case/0,
      fun provider_default_transport_and_rate_case/0,
      fun legacy_openai_default_injects_validated_model_case/0,
      fun explicit_legacy_transport_remains_unchanged_case/0,
      fun missing_provider_default_transport_fails_closed_case/0,
      fun openai_setup_preamble_then_acknowledgement_case/0,
      fun setup_preamble_does_not_extend_timeout_case/0]}.

setup() ->
    case whereis(adk_live_session_sup) of
        undefined ->
            {ok, Pid} = adk_live_session_sup:start_link(),
            unlink(Pid),
            {started, Pid};
        Pid -> {existing, Pid}
    end.

cleanup({started, Pid}) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Ref, [flush]),
        ok
    end;
cleanup({existing, _Pid}) -> ok.

profile_credential_is_brokered_and_redacted_case() ->
    Secret = <<"profile-live-runtime-secret">>,
    with_profiles(
      #{<<"openai-live">> => openai_profile(Secret)},
      fun() ->
          Config = (profile_session_config())#{
                     transport_opts =>
                         #{connect_timeout_ms => 500}},
          {ok, Checked} = adk_live_session:prepare_config(Config),
          CredentialRef = maps:get(credential_ref, Checked),
          try
              ?assertEqual(adk_live_openai,
                           maps:get(provider, Checked)),
              ?assertEqual(adk_live_openai_gun_transport,
                           maps:get(transport, Checked)),
              ?assertEqual(<<"gpt-realtime-profile-id">>,
                           maps:get(model,
                                    maps:get(provider_config, Checked))),
              ?assertEqual(24000,
                           maps:get(input_audio_sample_rate, Checked)),
              TransportOptions = maps:get(transport_opts, Checked),
              ?assertEqual(<<"gpt-realtime-profile-id">>,
                           maps:get(model, TransportOptions)),
              ?assertEqual(500,
                           maps:get(connect_timeout_ms, TransportOptions)),
              ?assertNot(maps:is_key(api_key, TransportOptions)),
              ?assertNot(maps:is_key(credential_profile, Checked)),
              ?assertEqual(nomatch,
                           binary:match(term_to_binary(Checked), Secret)),
              {ok, Secret} =
                  adk_live_credential_broker:resolve(CredentialRef),
              {adk_live_credential, Broker, _Token} = CredentialRef,
              ?assertEqual(
                 nomatch,
                 binary:match(term_to_binary(sys:get_state(Broker)),
                              Secret)),
              Diagnostic = adk_live_session:format_status(
                             #{state => Checked,
                               message => Secret,
                               reason => Secret}),
              ?assertEqual(nomatch,
                           binary:match(term_to_binary(Diagnostic), Secret))
          after
              ok = adk_live_credential_broker:revoke(CredentialRef)
          end
      end).

profile_transport_authority_is_rejected_case() ->
    Secret = <<"profile-live-override-secret">>,
    with_profiles(
      #{<<"openai-live">> => openai_profile(Secret)},
      fun() ->
          Base = profile_session_config(),
          Rejected =
              [Base#{transport => adk_live_fake_transport},
               Base#{transport_opts => #{api_key => <<"caller-key">>}},
               Base#{transport_opts => #{credential_ref => make_ref()}},
               Base#{transport_opts => #{model => <<"caller-model">>}},
               Base#{transport_opts => #{cacertfile => <<"/tmp/ca">>}},
               Base#{transport_opts =>
                         #{organization => <<"caller-organization">>}},
               Base#{transport_opts =>
                         #{project => <<"caller-project">>}}],
          lists:foreach(
            fun(Config) ->
                Result = adk_live_session:prepare_config(Config),
                ?assertEqual(
                   {error, provider_profile_override_not_allowed}, Result),
                ?assertEqual(nomatch,
                             binary:match(term_to_binary(Result), Secret))
            end, Rejected),
          ?assertMatch(
             {error, {invalid_live_transport_option, test_pid}},
             adk_live_session:prepare_config(
               Base#{transport_opts => #{test_pid => self()}}))
      end).

handoff_and_policy_share_rejection_case() ->
    Config = #{provider => adk_live_openai,
               provider_config => #{response_modalities => [text]},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()},
               unsupported_runtime_option => true},
    Expected = adk_live_session:prepare_config(Config),
    ?assertEqual(
       {error, {invalid_live_session_option, unsupported_runtime_option}},
       Expected),
    HandoffRef = make_ref(),
    {ok, Session} = adk_live_session:start_link(HandoffRef),
    try
        ?assertEqual(
           Expected,
           adk_live_session:handoff(
             Session, HandoffRef, <<"policy-parity-session">>,
             ?PRINCIPAL, Config))
    after
        ok = gen_statem:stop(Session)
    end.

provider_default_transport_and_rate_case() ->
    SessionId = unique_session_id(<<"default-transport">>),
    Config = #{provider => adk_live_default_transport_fixture_provider,
               provider_config => #{},
               transport_opts => #{test_pid => self()}},
    {ok, Session} = adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = receive_opened(),
    ?assertEqual(<<"fixture-setup">>, receive_sent(Handle)),
    {ok, Pending} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(setup_pending, maps:get(state, Pending)),
    ?assertEqual(32000, maps:get(input_audio_sample_rate, Pending)),
    adk_live_fake_transport:inject(Handle, <<"fixture-ready">>),
    wait_for_state(Session, active, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

legacy_openai_default_injects_validated_model_case() ->
    Secret = <<"legacy-openai-live-secret">>,
    Base = #{provider => adk_live_openai,
             provider_config => #{response_modalities => [text]},
             transport_opts => #{api_key => Secret}},
    {ok, Checked} = adk_live_session:prepare_config(Base),
    CredentialRef = maps:get(credential_ref, Checked),
    try
        ?assertEqual(adk_live_openai_gun_transport,
                     maps:get(transport, Checked)),
        ?assertEqual(adk_live_openai:model(),
                     maps:get(model, maps:get(transport_opts, Checked))),
        ?assertEqual(24000, maps:get(input_audio_sample_rate, Checked)),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Checked), Secret))
    after
        ok = adk_live_credential_broker:revoke(CredentialRef)
    end,
    Conflict = Base#{transport_opts =>
                         #{api_key => Secret,
                           model => <<"conflicting-model">>}},
    ConflictResult = adk_live_session:prepare_config(Conflict),
    ?assertEqual({error, conflicting_live_transport_model},
                 ConflictResult),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(ConflictResult), Secret)).

explicit_legacy_transport_remains_unchanged_case() ->
    {ok, Checked} = adk_live_session:prepare_config(
                      #{provider => adk_live_openai,
                        provider_config => #{response_modalities => [text]},
                        transport => adk_live_fake_transport,
                        transport_opts => #{test_pid => self()}}),
    ?assertEqual(adk_live_fake_transport, maps:get(transport, Checked)),
    ?assertEqual(#{test_pid => self()}, maps:get(transport_opts, Checked)),
    ?assertEqual(24000, maps:get(input_audio_sample_rate, Checked)).

missing_provider_default_transport_fails_closed_case() ->
    ?assertEqual(
       {error, invalid_live_session_config},
       adk_live_session:prepare_config(
         #{provider => adk_live_multi_frame_fixture_provider,
           provider_config => #{}, transport_opts => #{}})).

openai_setup_preamble_then_acknowledgement_case() ->
    {SessionId, Session, Handle} = start_openai_session(1000),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL, #{messages => 2, bytes => 4096}),
    adk_live_fake_transport:inject(
      Handle, #{<<"type">> => <<"session.created">>}),
    wait_for_state(Session, setup_pending, 50),
    assert_no_transport_close(Handle, 50),
    adk_live_fake_transport:inject(
      Handle, #{<<"type">> => <<"session.updated">>}),
    receive
        {adk_live_event, SessionId, Sequence, Event} ->
            ?assertEqual(ready, adk_live_event:kind(Event)),
            ok = adk_live_session:ack(
                   Session, ?PRINCIPAL, Sequence)
    after 1000 ->
        ?assert(false)
    end,
    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(active, maps:get(state, Status)),
    ?assertEqual(24000, maps:get(input_audio_sample_rate, Status)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

setup_preamble_does_not_extend_timeout_case() ->
    {_SessionId, Session, Handle} = start_openai_session(400),
    adk_live_fake_transport:inject(
      Handle, #{<<"type">> => <<"session.created">>}),
    timer:sleep(250),
    adk_live_fake_transport:inject(
      Handle, #{<<"type">> => <<"session.created">>}),
    receive
        {adk_live_fake_transport, closed, Handle, setup_timeout} -> ok
    after 250 ->
        ?assert(false)
    end,
    wait_for_state(Session, closed, 50).

start_openai_session(SetupTimeout) ->
    SessionId = unique_session_id(<<"openai-preamble">>),
    Config = #{provider => adk_live_openai,
               provider_config => #{response_modalities => [text]},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()},
               setup_timeout_ms => SetupTimeout},
    {ok, Session} = adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = receive_opened(),
    SetupFrame = receive_sent(Handle),
    #{<<"type">> := <<"session.update">>} =
        jsx:decode(SetupFrame, [return_maps]),
    {SessionId, Session, Handle}.

profile_session_config() ->
    #{provider => <<"openai-live">>,
      provider_config => #{model => <<"voice">>,
                           response_modalities => [text]}}.

openai_profile(Secret) ->
    #{live_adapter => adk_live_openai,
      endpoint => openai,
      models => #{<<"voice">> => <<"gpt-realtime-profile-id">>},
      credential => {literal, Secret},
      capabilities => #{live => true}}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_env(provider_profiles, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_env(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).

unique_session_id(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

receive_opened() ->
    receive
        {adk_live_fake_transport, opened, Handle} -> Handle
    after 1000 ->
        ?assert(false)
    end.

receive_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} -> Frame
    after 1000 ->
        ?assert(false)
    end.

assert_no_transport_close(Handle, Timeout) ->
    receive
        {adk_live_fake_transport, closed, Handle, _Reason} ->
            ?assert(false)
    after Timeout -> ok
    end.

wait_for_state(_Session, _Expected, 0) -> ?assert(false);
wait_for_state(Session, Expected, Attempts) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := Expected}} -> ok;
        _ ->
            timer:sleep(10),
            wait_for_state(Session, Expected, Attempts - 1)
    end.
