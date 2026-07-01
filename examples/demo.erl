-module(demo).
-export([run/0]).

run() ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    application:ensure_all_started(erlang_adk),
    
    %% Setup configs for agents with Session Persistence
    AliceConfig = #{
        provider => adk_llm_gemini,
        instructions => "You are Alice, a poet. You write short 4-line poems. Be highly creative.",
        session_id => alice_session_1
    },
    
    BobConfig = #{
        provider => adk_llm_gemini,
        instructions => "You are Bob, an editor. You provide critical review. Be concise.",
        session_id => bob_session_1
    },

    io:format("Spawning Alice (Writer) and Bob (Reviewer) with ETS memory...~n"),
    {ok, AlicePid} = erlang_adk:spawn_agent("Alice", AliceConfig, []),
    {ok, BobPid} = erlang_adk:spawn_agent("Bob", BobConfig, []),
    
    io:format("~nStarting an Orchestrator Loop between Alice and Bob...~n"),
    io:format("Alice will draft a poem about Erlang OTP supervisors. Bob will review it. Alice will revise it. (Max 2 iterations)~n"),
    
    Prompt = "Write a short 4-line poem about Erlang OTP supervisors.",
    case erlang_adk:loop(AlicePid, BobPid, Prompt, 2) of
        {ok, FinalDraft} ->
            io:format("~n=== FINAL DRAFT AFTER ORCHESTRATION ===~n~ts~n", [FinalDraft]);
        {error, Reason} ->
            io:format("Loop failed: ~p~n", [Reason])
    end,
    
    erlang_adk_session:delete(alice_session_1),
    erlang_adk_session:delete(bob_session_1),
    
    application:stop(erlang_adk),
    ok.
