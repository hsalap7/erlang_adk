%% @doc Bounded low-cardinality metric aggregation for Erlang ADK.
%%
%% This is an SDK-neutral registry.  It keeps a small in-memory snapshot that
%% an OpenTelemetry/Prometheus adapter may scrape.  Series beyond the configured
%% per-instrument cap are merged into one explicit overflow series instead of
%% allocating labels without bound.
-module(adk_observability_metrics).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         record/4, record/5, snapshot/0, snapshot/1,
         reset/0, reset/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_INSTRUMENTS, 64).
-define(DEFAULT_MAX_SERIES, 200).

-record(state, {
    instruments = #{} :: map(),
    max_instruments = ?DEFAULT_MAX_INSTRUMENTS :: pos_integer(),
    max_series = ?DEFAULT_MAX_SERIES :: pos_integer(),
    overflow_records = 0 :: non_neg_integer(),
    rejected_records = 0 :: non_neg_integer()
}).

start_link() -> start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    Name = maps:get(name, Opts, ?SERVER),
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

child_spec(Opts) ->
    #{id => maps:get(name, Opts, ?SERVER),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

record(Name, Type, Value, Labels) ->
    record(?SERVER, Name, Type, Value, Labels).

record(Server, Name, Type, Value, Labels) ->
    gen_server:call(Server, {record, Name, Type, Value, Labels}).

snapshot() -> snapshot(?SERVER).
snapshot(Server) -> gen_server:call(Server, snapshot).

reset() -> reset(?SERVER).
reset(Server) -> gen_server:call(Server, reset).

init(Opts) ->
    process_flag(message_queue_data, off_heap),
    Allowed = [name, max_instruments, max_series_per_instrument],
    Unknown = maps:keys(maps:without(Allowed, Opts)),
    MaxInstruments = maps:get(max_instruments, Opts,
                              ?DEFAULT_MAX_INSTRUMENTS),
    MaxSeries = maps:get(max_series_per_instrument, Opts,
                         ?DEFAULT_MAX_SERIES),
    case {Unknown, valid_limit(MaxInstruments, 4096),
          valid_limit(MaxSeries, 10000)} of
        {[], true, true} ->
            {ok, #state{max_instruments = MaxInstruments,
                        max_series = MaxSeries}};
        {[_ | _], _, _} ->
            {stop, {invalid_metric_options,
                    {unknown_keys, lists:sort(Unknown)}}};
        _ -> {stop, invalid_metric_options}
    end.

handle_call({record, Name0, Type, Value, Labels0}, _From, State0) ->
    case normalize_record(Name0, Type, Value, Labels0) of
        {ok, Name, CanonicalType, Number, Labels} ->
            case update_instrument(Name, CanonicalType, Number, Labels,
                                   State0) of
                {ok, State1, Overflowed} ->
                    {reply, {ok, #{overflow => Overflowed}}, State1};
                {error, Reason, State1} ->
                    {reply, {error, Reason}, State1}
            end;
        {error, Reason} ->
            {reply, {error, Reason},
             State0#state{rejected_records =
                            State0#state.rejected_records + 1}}
    end;
handle_call(snapshot, _From, State) ->
    {reply, public_snapshot(State), State};
handle_call(reset, _From, State) ->
    {reply, ok, State#state{instruments = #{},
                            overflow_records = 0,
                            rejected_records = 0}};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

normalize_record(Name0, Type, Value, Labels0) ->
    case {normalize_name(Name0), normalize_type(Type),
          normalize_number(Type, Value),
          adk_genai_semconv:metric_labels(Labels0)} of
        {{ok, Name}, {ok, CanonicalType}, {ok, Number}, {ok, Labels}} ->
            {ok, Name, CanonicalType, Number, Labels};
        {{error, _}, _, _, _} -> {error, invalid_metric_name};
        {_, {error, _}, _, _} -> {error, invalid_metric_type};
        {_, _, {error, _}, _} -> {error, invalid_metric_value};
        {_, _, _, {error, _}} -> {error, invalid_metric_labels}
    end.

normalize_name(Name) when is_atom(Name) ->
    normalize_name(atom_to_binary(Name, utf8));
normalize_name(Name) when is_binary(Name), byte_size(Name) > 0,
                               byte_size(Name) =< 128 ->
    case lists:all(fun valid_name_char/1, binary_to_list(Name)) of
        true -> {ok, Name};
        false -> {error, invalid}
    end;
normalize_name(_) -> {error, invalid}.

valid_name_char(Char) when Char >= $a, Char =< $z -> true;
valid_name_char(Char) when Char >= $0, Char =< $9 -> true;
valid_name_char($_) -> true;
valid_name_char($.) -> true;
valid_name_char(_) -> false.

normalize_type(counter) -> {ok, counter};
normalize_type(histogram) -> {ok, histogram};
normalize_type(gauge) -> {ok, gauge};
normalize_type(_) -> {error, invalid}.

normalize_number(counter, Value) when (is_integer(Value) orelse
                                       is_float(Value)), Value >= 0 ->
    {ok, Value};
normalize_number(Type, Value) when (Type =:= histogram orelse Type =:= gauge),
                                   (is_integer(Value) orelse is_float(Value)) ->
    {ok, Value};
normalize_number(_, _) -> {error, invalid}.

update_instrument(Name, Type, Value, Labels,
                  State = #state{instruments = Instruments,
                                 max_instruments = Max}) ->
    case maps:find(Name, Instruments) of
        {ok, #{type := Type} = Instrument} ->
            update_series(Name, Instrument, Value, Labels, State);
        {ok, _OtherType} ->
            {error, metric_type_conflict,
             State#state{rejected_records =
                           State#state.rejected_records + 1}};
        error when map_size(Instruments) < Max ->
            Instrument = #{type => Type, series => #{}, overflow => none},
            update_series(Name, Instrument, Value, Labels, State);
        error ->
            {error, metric_instrument_limit,
             State#state{rejected_records =
                           State#state.rejected_records + 1}}
    end.

update_series(Name, Instrument, Value, Labels,
              State = #state{instruments = Instruments,
                             max_series = MaxSeries}) ->
    Series = maps:get(series, Instrument),
    Key = label_key(Labels),
    case maps:find(Key, Series) of
        {ok, Existing} ->
            Updated = update_value(maps:get(type, Instrument),
                                   Existing, Value),
            NewInstrument = Instrument#{series => Series#{Key => Updated}},
            {ok, State#state{instruments =
                              Instruments#{Name => NewInstrument}}, false};
        error when map_size(Series) < MaxSeries ->
            Entry = new_value(maps:get(type, Instrument), Value, Labels),
            NewInstrument = Instrument#{series => Series#{Key => Entry}},
            {ok, State#state{instruments =
                              Instruments#{Name => NewInstrument}}, false};
        error ->
            Overflow0 = maps:get(overflow, Instrument),
            OverflowLabels = #{<<"otel.metric.overflow">> => true},
            Overflow1 = case Overflow0 of
                none -> new_value(maps:get(type, Instrument), Value,
                                  OverflowLabels);
                ExistingOverflow ->
                    update_value(maps:get(type, Instrument),
                                 ExistingOverflow, Value)
            end,
            NewInstrument = Instrument#{overflow => Overflow1},
            {ok, State#state{
                   instruments = Instruments#{Name => NewInstrument},
                   overflow_records = State#state.overflow_records + 1}, true}
    end.

label_key(Labels) -> lists:sort(maps:to_list(Labels)).

new_value(counter, Value, Labels) ->
    #{labels => Labels, value => Value};
new_value(gauge, Value, Labels) ->
    #{labels => Labels, value => Value};
new_value(histogram, Value, Labels) ->
    #{labels => Labels, count => 1, sum => Value,
      min => Value, max => Value}.

update_value(counter, Entry, Value) ->
    Entry#{value => maps:get(value, Entry) + Value};
update_value(gauge, Entry, Value) -> Entry#{value => Value};
update_value(histogram, Entry, Value) ->
    Entry#{count => maps:get(count, Entry) + 1,
           sum => maps:get(sum, Entry) + Value,
           min => erlang:min(maps:get(min, Entry), Value),
           max => erlang:max(maps:get(max, Entry), Value)}.

public_snapshot(#state{instruments = Instruments,
                       max_instruments = MaxInstruments,
                       max_series = MaxSeries,
                       overflow_records = Overflow,
                       rejected_records = Rejected}) ->
    Public = maps:map(
               fun(_Name, Instrument) ->
                   Series0 = maps:values(maps:get(series, Instrument)),
                   Series = case maps:get(overflow, Instrument) of
                       none -> Series0;
                       OverflowSeries -> Series0 ++ [OverflowSeries]
                   end,
                   #{<<"type">> => atom_to_binary(
                                      maps:get(type, Instrument), utf8),
                     <<"series">> => Series}
               end, Instruments),
    #{<<"instruments">> => Public,
      <<"instrument_count">> => map_size(Instruments),
      <<"max_instruments">> => MaxInstruments,
      <<"max_series_per_instrument">> => MaxSeries,
      <<"overflow_records">> => Overflow,
      <<"rejected_records">> => Rejected}.

valid_limit(Value, Max) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Max.
