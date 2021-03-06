%%%-------------------------------------------------------------------
%%% File        : ecomponent.erl
%%% Author      : Jose Luis Navarro <pepe@yuilop.com>
%%%               Manuel Rubio <manuel@yuilop.com>
%%% Description : ecomponent Service - External Component
%%%-------------------------------------------------------------------
-module(ecomponent).

-behaviour(gen_server).

-include("../include/ecomponent_internal.hrl").

%% API
-export([prepare_id/1, unprepare_id/1, get_processor/1, get_processor_by_ns/1,
        get_message_processor/0, get_presence_processor/0, send/4, send/3, send/2, send_message/1,
        send_presence/1, save_id/4, syslog/2, configure/0, gen_id/0, reset_countdown/1, get_countdown/1,
        sync_send/2]).

%% gen_server callbacks
-export([start_link/0, stop/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-spec start_link() -> {ok, Pid::pid()} | {error, Reason::any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.

stop() ->
    gen_server:call(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init( Args :: [] ) -> 
    {ok, State :: #state{}} | 
    {ok, State :: #state{}, hibernate | infinity | non_neg_integer()} |
    ignore | {stop, Reason :: string()}.

init([]) ->
    lager:info("Loading Application eComponent", []),
    configure().

-spec handle_info(Msg::any(), State::#state{}) ->
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), State::#state{}}.

handle_info(
        #received_packet{packet_type=iq, type_attr=Type, raw_packet=IQ, from={Node, Domain, _}=From}, 
        #state{
            maxPerPeriod=MaxPerPeriod, periodSeconds=PeriodSeconds, 
            features=Features,info=Info,disco_info=DiscoInfo
        }=State) ->
    NS = exmpp_iq:get_payload_ns_as_atom(IQ),
    spawn(metrics, notify_throughput_iq, [in, Type, NS]),
    case mod_monitor:accept(list_to_binary(exmpp_jid:to_list(Node, Domain)), MaxPerPeriod, PeriodSeconds) of
        true ->
            spawn(metrics, set_iq_time, [exmpp_stanza:get_id(IQ), Type, NS]),
            if
                (DiscoInfo =:= false) andalso (?NS_DISCO_INFO =:= NS) ->
                    lager:debug("Ignored by disco#info muted! NS=~p~n", [NS]),
                    ignore;
                true ->
                    lager:debug("To process packet with NS=~p~n", [NS]),
                    spawn(iq_handler, pre_process_iq, [Type, IQ, NS, From, Features, Info])
            end,
            {noreply, State, get_countdown(State)};
        false ->
            spawn(metrics, notify_dropped_iq, [Type, NS]),
            {noreply, State, get_countdown(State)}
    end;

handle_info(#received_packet{packet_type=message, type_attr=Type, raw_packet=Message, from={Node, Domain, _}=From}, #state{maxPerPeriod=MaxPerPeriod, periodSeconds=PeriodSeconds}=State) ->
    spawn(metrics, notify_throughput_message, [in, Type]),
    case mod_monitor:accept(list_to_binary(exmpp_jid:to_list(Node, Domain)), MaxPerPeriod, PeriodSeconds) of
        true ->
            spawn(message_handler, pre_process_message, [Type, Message, From]),
            {noreply, State};
        _ ->
            spawn(metrics, notify_dropped_message, [Type]),
            {noreply, State}
    end;


handle_info(#received_packet{packet_type=presence, type_attr=Type, raw_packet=Presence, from={Node, Domain, _}=From}, #state{maxPerPeriod=MaxPerPeriod, periodSeconds=PeriodSeconds}=State) ->
    spawn(metrics, notify_throughput_presence, [in, Type]),
    case mod_monitor:accept(list_to_binary(exmpp_jid:to_list(Node, Domain)), MaxPerPeriod, PeriodSeconds) of
        true ->
            spawn(presence_handler, pre_process_presence, [Type, Presence, From]),
            {noreply, State};
        _ ->
            spawn(metrics, notify_dropped_presence, [Type]),
            {noreply, State}
    end;

handle_info({send, OPacket, NS, App, Reply}, #state{jid=JID}=State) ->
    Kind = exmpp_iq:get_kind(OPacket),
    From = exmpp_stanza:get_sender(OPacket),
    NewPacket = case From of
        undefined ->
            exmpp_xml:set_attribute(OPacket, <<"from">>, JID);
        _ ->
            OPacket
    end,
    Packet = case exmpp_stanza:get_id(NewPacket) of
        undefined ->
            ID = gen_id(),
            exmpp_xml:set_attribute(NewPacket, <<"id">>, ID);
        _ -> 
            NewPacket
    end,
    case Kind of
        request when Reply =:= false ->
            spawn(metrics, notify_throughput_iq, [out, exmpp_iq:get_type(Packet), NS]);
        request ->
            spawn(metrics, notify_throughput_iq, [out, exmpp_iq:get_type(Packet), NS]),
            save_id(exmpp_stanza:get_id(Packet), NS, Packet, App);
        _ -> 
            spawn(metrics, notify_resp_time, [exmpp_stanza:get_id(Packet)])
    end,
    lager:debug("Sending packet ~p",[Packet]),
    ecomponent_con:send(Packet), 
    {noreply, State, get_countdown(State)};

handle_info({send_message, OPacket}, #state{jid=JID}=State) ->
    From = exmpp_stanza:get_sender(OPacket),
    NewPacket = case From of
        undefined ->
            exmpp_xml:set_attribute(OPacket, <<"from">>, JID);
        _ ->
            OPacket
    end,
    Packet = case exmpp_stanza:get_id(NewPacket) of
        undefined ->
            ID = gen_id(),
            exmpp_xml:set_attribute(NewPacket, <<"id">>, ID);
        _ -> 
            NewPacket
    end,
    lager:debug("Sending packet ~p",[Packet]),
    spawn(metrics, notify_throughput_message, [out, case exmpp_stanza:get_type(Packet) of
        undefined -> <<"normal">>;
        Type -> Type
    end]),
    ecomponent_con:send(Packet), 
    {noreply, State, get_countdown(State)};


handle_info({send_presence, OPacket}, #state{jid=JID}=State) ->
    From = exmpp_stanza:get_sender(OPacket),
    NewPacket = case From of
        undefined ->
            exmpp_xml:set_attribute(OPacket, <<"from">>, JID);
        _ ->
            OPacket
    end,
    Packet = case exmpp_stanza:get_id(NewPacket) of
        undefined ->
            ID = gen_id(),
            exmpp_xml:set_attribute(NewPacket, <<"id">>, ID);
        _ -> 
            NewPacket
    end,
    lager:debug("Sending packet ~p",[Packet]),
    spawn(metrics, notify_throughput_presence, [out, case exmpp_stanza:get_type(Packet) of 
        undefined -> <<"available">>;
        Type -> Type 
    end]),
    ecomponent_con:send(Packet), 
    {noreply, State, get_countdown(State)};

handle_info({resend, #matching{tries=Tries, packet=P}=N}, #state{maxTries=Max}=State) when Tries < Max ->
    save_id(N#matching{tries=Tries+1}),
    ecomponent_con:send(P), 
    {noreply, State, get_countdown(State)};

handle_info({resend, #matching{tries=Tries}=N}, #state{maxTries=Max}=State) when Tries >= Max ->
    lager:warning("Max tries exceeded for: ~p~n", [N]),
    {noreply, State, get_countdown(State)};

handle_info(timeout, #state{requestTimeout=RT}=State) ->
    expired_stanzas(RT),
    {noreply, reset_countdown(State), State#state.requestTimeout};

handle_info(Record, State) -> 
    lager:info("Unknown Info Request: ~p~n", [Record]),
    {noreply, State, get_countdown(State)}.

-spec handle_cast(Msg::any(), State::#state{}) ->
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), State::#state{}}.

handle_cast(_Msg, State) ->
    lager:info("Received: ~p~n", [_Msg]), 
    {noreply, State, get_countdown(State)}.


-spec handle_call(Msg::any(), From::{pid(),_}, State::#state{}) ->
    {reply, Reply::any(), State::#state{}} |
    {reply, Reply::any(), State::#state{}, hibernate | infinity | non_neg_integer()} |
    {noreply, State::#state{}} |
    {noreply, State::#state{}, hibernate | infinity | non_neg_integer()} |
    {stop, Reason::any(), Reply::any(), State::#state{}} |
    {stop, Reason::any(), State::#state{}}.

handle_call({access_list_set, NS, Jid} = Info, _From, State) ->
    lager:debug("Received Call: ~p~n", [Info]),
    {reply, is_allowed(set, NS, Jid, State), State, get_countdown(State)};

handle_call({access_list_get, NS, Jid} = Info, _From, State) ->
    lager:debug("Received Call: ~p~n", [Info]),
    {reply, is_allowed(get, NS, Jid, State), State, get_countdown(State)};

handle_call({change_config, syslog, {Facility, Name}}, _From, State) ->
    init_syslog(if
        is_number(Facility) -> Facility;
        true -> list_to_atom(Facility)
    end, Name),
    {reply, ok, State, get_countdown(State)};

handle_call({change_config, Key, Value}, _From, State) ->
    case Key of
        maxPerPeriod -> {reply, ok, State#state{maxPerPeriod=Value}, get_countdown(State)};
        periodSeconds -> {reply, ok, State#state{periodSeconds=Value}, get_countdown(State)};
        maxTries -> {reply, ok, State#state{maxTries=Value}, get_countdown(State)};
        resendPeriod -> {reply, ok, State#state{resendPeriod=Value}, get_countdown(State)};
        requestTimeout -> {reply, ok, State#state{requestTimeout=Value}, get_countdown(State)};
        _ -> {reply, error, State, get_countdown(State)}
    end;

handle_call(message_processor, _From, State) ->
    {reply, State#state.message_processor, State, get_countdown(State)};

handle_call(presence_processor, _From, State) ->
    {reply, State#state.presence_processor, State, get_countdown(State)};

handle_call(stop, _From, State) ->
    lager:info("Component Stopped.~n",[]),
    ecomponent_con:stop(),
    {stop, normal, ok, State};

handle_call(Info, _From, State) ->
    lager:info("Received Call: ~p~n", [Info]),
    {reply, ok, State, get_countdown(State)}.


-spec terminate(Reason::any(), State::#state{}) -> ok.

terminate(_Reason, _State) ->
    lager:info("Terminated Component.", []),
    ok.

-spec code_change(OldVsn::string(), State::#state{}, Extra::any()) ->
    {ok, State::#state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec reset_countdown(State::#state{}) -> #state{}.

reset_countdown(State) ->
    {A,B,_} = now(),
    State#state{timeout=(A*1000000+B)}.

-spec get_countdown(Begin::integer()) -> integer().

get_countdown(#state{timeout=undefined}) ->
    100;
get_countdown(#state{timeout=Begin,requestTimeout=RT}) ->
    {A,B,_} = now(),
    case ((A * 1000000 + B) - Begin) of
        Time when (RT - Time) > 0 ->
            (RT - Time) * 1000;
        _ ->
            100
    end.

-spec configure() -> {ok, #state{}}.

configure() ->
    Conf = ?FETCH(mgmt_conf, ecomponent, []),
    Facility = proplists:get_value(syslog_facility, Conf, local7),
    Name = proplists:get_value(syslog_name, Conf, "ecomponent"),
    init_syslog(Facility, Name),
    [ lager:info("~p = ~p", [X,Y]) || {X,Y} <- Conf ],

    JID = proplists:get_value(jid, Conf),
    WhiteList = proplists:get_value(whitelist, Conf, []),
    Processors = proplists:get_value(processors, Conf, []),

    ecomponent_con:start_link(JID, Conf),
    ecomponent_mnesia:init(Conf), 
    mod_monitor:init(WhiteList),
    metrics:init(),
    prepare_processors(Processors),
    {ok, reset_countdown(#state{
        jid = JID,
        whiteList = WhiteList,
        maxPerPeriod = proplists:get_value(max_per_period, Conf, ?MAX_PER_PERIOD),
        periodSeconds = proplists:get_value(period_seconds, Conf, ?PERIOD_SECONDS),
        processors = proplists:get_value(processors, Conf),
        message_processor = proplists:get_value(message_processor, Conf, undefined),
        presence_processor = proplists:get_value(presence_processor, Conf, undefined),
        maxTries = proplists:get_value(max_tries, Conf, ?MAX_TRIES),
        resendPeriod = proplists:get_value(resend_period, Conf, ?RESEND_PERIOD),
        requestTimeout = proplists:get_value(request_timeout, Conf, ?REQUEST_TIMEOUT),
        accessListSet = proplists:get_value(access_list_set, Conf, []),
        accessListGet = proplists:get_value(access_list_get, Conf, []),
        features = proplists:get_value(features, Conf, []),
        info = proplists:get_value(info, Conf, []), 
        disco_info = proplists:get_value(disco_info, Conf, true) 
    })}.

-spec gen_id() -> binary().

gen_id() ->
    list_to_binary(uuid:to_string(uuid:uuid4())).

-spec expired_stanzas(Timeout::integer()) -> ok.

expired_stanzas(Timeout) ->
    [ resend(N) || {_K, N} <- timem:remove_expired(Timeout), is_record(N, matching) ],
    ok.

-spec resend(N :: #matching{}) -> ok.

resend(N) when is_record(N, matching) ->
    ?MODULE ! {resend, N},
    ok.

-spec init_syslog(Facility::(atom() | integer()), Name::string()) -> ok | {error, Reason::any()}.

init_syslog(Facility, Name) ->
    lager:info("Syslog configured: facility=~p, name=~p",[Facility, Name]),
    syslog:open(Name, [cons, perror, pid], Facility).

-spec save_id(Id::binary(), NS::string(), Packet::term(), App::atom()) -> #matching{} | ok.

save_id(_Id, _NS, _Packet, ecomponent) ->
    ok;

save_id(Id, NS, Packet, App) ->
    N = #matching{id=Id, ns=NS, processor=App, tries=0, packet=Packet},
    save_id(N).

-spec save_id(N::#matching{}) -> #matching{} | ok.
    
save_id(#matching{id=Id, processor=App}=N) ->
    case timem:insert(Id, N) of
        true ->
            N;
        _ ->
            lager:error("Error writing id ~s, processor ~p on timem, reason: ~p", [Id, App])
    end.

-spec get_processor(Id::binary()) -> #matching{} | undefined.

get_processor(Id) ->
    case timem:remove(Id) of
        {_, N} when is_record(N, matching) -> 
            N;
        _ ->
            lager:warning("Found no matching processor for id [~p]",[Id]),
            undefined
    end.

-spec prepare_processors(P::list(processor())) -> ok.

prepare_processors(P) ->
    case ets:info(?NS_PROCESSOR) of
        undefined ->
            ets:new(?NS_PROCESSOR, [named_table, public]);
        _ ->
            ets:delete_all_objects(?NS_PROCESSOR)
    end,
    [ 
        ets:insert(?NS_PROCESSOR, {NS, {Type, Processor}}) ||
        {NS, {Type, Processor}} <- P
    ],
    ok.

-spec get_processor_by_ns(NS::atom()) -> [] | mod_processor() | app_processor().

get_processor_by_ns(NS) ->
    case ets:lookup(?NS_PROCESSOR, NS) of
        [{_, {_T, _P}=Result}] -> Result;
        _ ->
            case ets:lookup(?NS_PROCESSOR, default) of
                [{_, {_T, _P}=Result}] -> Result;
                _ -> undefined
            end
    end.

-spec get_message_processor() -> undefined | mod_processor() | app_processor().

get_message_processor() ->
    PID = whereis(?MODULE),
    case erlang:is_pid(PID) of
        true ->
            gen_server:call(PID, message_processor);
        _ -> 
            syslog(crit, io_lib:format("Process not Alive with Name: ~p~n", [?MODULE]))
    end.

-spec get_presence_processor() -> undefined | mod_processor() | app_processor().

get_presence_processor() ->
    PID = whereis(?MODULE),
    case erlang:is_pid(PID) of
        true ->
            gen_server:call(PID, presence_processor);
        _ -> 
            syslog(crit, io_lib:format("Process not Alive with Name: ~p~n", [?MODULE]))
    end.

-spec prepare_id(Data::string()) -> string().

prepare_id([]) -> [];
prepare_id([$<|T]) -> [$x|prepare_id(T)];
prepare_id([$>|T]) -> [$X|prepare_id(T)];
prepare_id([H|T]) -> [H|prepare_id(T)].

-spec unprepare_id(Data::string()) -> string().

unprepare_id([]) -> [];
unprepare_id([$x|T]) -> [$<|unprepare_id(T)];
unprepare_id([$X|T]) -> [$>|unprepare_id(T)];
unprepare_id([H|T]) -> [H|unprepare_id(T)].

-spec send(Packet::term(), App::atom()) -> ok.

send(Packet, App) ->
    Payload = exmpp_iq:get_payload(Packet),
    NS = exmpp_xml:get_ns_as_atom(Payload),
    send(Packet, NS, App, true).

-spec send(Packet::term(), NS::atom(), App::atom()) -> ok.

send(Packet, NS, App) ->
    send(Packet, NS, App, true).

-spec send(Packet::term(), NS::atom(), App::atom(), Reply::boolean()) -> ok.

send(Packet, NS, App, Reply) ->
    ?MODULE ! {send, Packet, NS, App, Reply},
    ok.

-spec sync_send(Packet::term(), NS::atom()) -> #params{} | {error, timeout}.

sync_send(Packet, NS) ->
    send(Packet, NS, self(), true),
    receive 
        #response{params=Params=#params{type="result"}} ->
            Params
    after 5000 ->
        {error, timeout}
    end.

-spec send_message(Packet::term()) -> ok.

send_message(Packet) ->
    ?MODULE ! {send_message, Packet},
    ok.

-spec send_presence(Packet::term()) -> ok.

send_presence(Packet) ->
    ?MODULE ! {send_presence, Packet},
    ok.

-spec is_allowed( (set | get | error | result), NS::atom(), JID::jid(), State::#state{}) -> boolean().

is_allowed(Type, NS, {Node,Domain,Res}, State) when is_list(Domain) ->
    is_allowed(Type, NS, {Node,list_to_binary(Domain),Res}, State);
is_allowed(set, NS, {_, Domain, _}, #state{accessListSet=As}) ->
    is_allowed(NS, Domain, As);
is_allowed(get, NS, {_, Domain, _}, #state{accessListGet=Ag}) ->
    is_allowed(NS, Domain, Ag).

-spec is_allowed( NS::atom(), Domain::string(), PList::list(binary()) ) -> boolean().

is_allowed(NS, Domain, PList) ->
    case proplists:get_value(NS, PList) of
        undefined ->
            true;
        List ->
            lists:member(Domain, List)
    end.

-type levels() :: emerg | alert | crit | err | warning | notice | info | debug.

-spec syslog(Level::levels(), Message::string()) -> ok.

%% Level: emerg, alert, crit, err, warning, notice, info, debug
syslog(Level, Message) when is_binary(Message) ->
    syslog(Level, erlang:binary_to_list(Message));
syslog(Level, Message) when is_list(Message) ->
    Priority = case Level of
        emerg -> "EMERG ";
        alert -> "ALERT ";
        crit -> "CRIT ";
        err -> "ERR ";
        warning -> "WARNING ";
        notice -> "NOTICE ";
        info -> "INFO ";
        debug -> "DEBUG ";
        _ -> ""
    end,
    syslog:log(Level, Priority ++ Message).
