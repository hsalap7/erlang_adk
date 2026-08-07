-module(adk_google_adc_fixture).

-export([access_token/1]).

access_token({notify, Owner, Result}) ->
    Owner ! google_adc_requested,
    Result;
access_token({raise, Secret}) ->
    erlang:error({adc_fixture_failure, Secret});
access_token(Result) -> Result.
