%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2013 VMware, Inc.  All rights reserved.
%%

-module(rabbit_amqp1_0_outgoing_link).

-export([attach/3, delivery/6, transfered/3, credit_drained/4, flow/3]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_amqp1_0.hrl").

-import(rabbit_amqp1_0_link_util, [protocol_error/3, handle_to_ctag/1]).
-import(rabbit_misc, [serial_add/2]).

-define(INIT_TXFR_COUNT, 0).
-define(DEFAULT_SEND_SETTLED, false).

-record(outgoing_link, {queue,
                        delivery_count = 0,
                        send_settled,
                        default_outcome}).

attach(#'v1_0.attach'{snd_settle_mode = SndSettleMode,
                      rcv_settle_mode = ?V_1_0_RECEIVER_SETTLE_MODE_SECOND},
       _, _) when SndSettleMode =/= ?V_1_0_SENDER_SETTLE_MODE_SETTLED ->
    protocol_error(?V_1_0_AMQP_ERROR_NOT_IMPLEMENTED,
                   "rcv-settle-mode=second not supported", []);
attach(#'v1_0.attach'{name = Name,
                      handle = Handle,
                      source = Source,
                      snd_settle_mode = SndSettleMode,
                      rcv_settle_mode = RcvSettleMode}, BCh, DCh) ->
    {DefaultOutcome, Outcomes} = rabbit_amqp1_0_link_util:outcomes(Source),
    SndSettled =
        case SndSettleMode of
            ?V_1_0_SENDER_SETTLE_MODE_SETTLED   -> true;
            ?V_1_0_SENDER_SETTLE_MODE_UNSETTLED -> false;
            _                                   -> ?DEFAULT_SEND_SETTLED
        end,
    DOSym = rabbit_amqp1_0_framing:symbol_for(DefaultOutcome),
    case ensure_source(Source,
                       #outgoing_link{delivery_count  = ?INIT_TXFR_COUNT,
                                      send_settled    = SndSettled,
                                      default_outcome = DOSym}, DCh) of
        {ok, Source1, OutgoingLink = #outgoing_link{queue = QueueName}} ->
            CTag = handle_to_ctag(Handle),
            case amqp_channel:subscribe(
                   BCh, #'basic.consume'{
                     queue = QueueName,
                     consumer_tag = CTag,
                     %% we will ack when we've transfered
                     %% a message, or when we get an ack
                     %% from the client.
                     no_ack = false,
                     %% TODO exclusive?
                     exclusive = false,
                     arguments = [{<<"x-credit">>, table,
                                   [{<<"credit">>, long,    0},
                                    {<<"drain">>,  boolean, false}]}]},
                   self()) of
                #'basic.consume_ok'{} ->
                    %% TODO we should avoid the race by getting the queue to send
                    %% attach back, but a.t.m. it would use the wrong codec.
                    {ok, [#'v1_0.attach'{
                       name = Name,
                       handle = Handle,
                       initial_delivery_count = {uint, ?INIT_TXFR_COUNT},
                       snd_settle_mode =
                           case SndSettled of
                               true  -> ?V_1_0_SENDER_SETTLE_MODE_SETTLED;
                               false -> ?V_1_0_SENDER_SETTLE_MODE_UNSETTLED
                           end,
                       rcv_settle_mode = RcvSettleMode,
                       source = Source1#'v1_0.source'{
                                  default_outcome = DefaultOutcome,
                                  outcomes        = Outcomes
                                 },
                       role = ?SEND_ROLE}], OutgoingLink};
                Fail ->
                    protocol_error(?V_1_0_AMQP_ERROR_INTERNAL_ERROR, "Consume failed: ~p", Fail)
            end;
        {error, _Reason} ->
            %% TODO Deal with this properly -- detach and what have you
            {ok, [#'v1_0.attach'{source = undefined}]}
    end.

credit_drained(#'basic.credit_drained'{credit_drained = CreditDrained},
               Handle, Link = #outgoing_link{delivery_count = Count0},
               WriterPid) ->
    Count = Count0 + CreditDrained,
    %% The transfer count that is given by the queue should be at
    %% least that we have locally, since we will either have received
    %% all the deliveries and transfered them, or the queue will have
    %% advanced it due to drain. So we adopt the queue's idea of the
    %% count.
    %% TODO account for it not being there any more
    F = #'v1_0.flow'{ handle      = Handle,
                      delivery_count = {uint, Count},
                      link_credit = {uint, 0},
                      available   = {uint, 0},
                      drain       = true },
    rabbit_amqp1_0_writer:send_command(WriterPid, F),
    Link#outgoing_link{delivery_count = Count}.

flow(#outgoing_link{delivery_count = LocalCount},
     #'v1_0.flow'{handle         = Handle,
                  delivery_count = Count0,
                  link_credit    = {uint, RemoteCredit},
                  drain          = Drain}, BCh) ->
    RemoteCount = case Count0 of
                      undefined     -> LocalCount;
                      {uint, Count} -> Count
                  end,
    %% See section 2.6.7
    LocalCredit = RemoteCount + RemoteCredit - LocalCount,
    CTag = handle_to_ctag(Handle),
    #'basic.credit_ok'{available = Available} =
        amqp_channel:call(BCh, #'basic.credit'{consumer_tag = CTag,
                                               credit       = LocalCredit,
                                               drain        = Drain}),
    case Available of
        -1 ->
            {ok, []};
        %% We don't know - probably because this flow relates
        %% to a handle that does not yet exist
        %% TODO is this an error?
        _  ->
            {ok, [#'v1_0.flow'{
                    handle         = Handle,
                    delivery_count = {uint, LocalCount},
                    link_credit    = {uint, LocalCredit},
                    available      = {uint, Available},
                    drain          = Drain}]}
    end.

%% TODO this looks to have a lot in common with ensure_target
ensure_source(Source = #'v1_0.source'{address       = Address,
                                      dynamic       = Dynamic,
                                      expiry_policy = _ExpiryPolicy, % TODO
                                      timeout       = Timeout},
              Link = #outgoing_link{}, DCh) ->
    case Dynamic of
        true ->
            case Address of
                undefined ->
                    {ok, QueueName} = rabbit_amqp1_0_link_util:create_queue(Timeout, DCh),
                    {ok,
                     Source#'v1_0.source'{address = {utf8, rabbit_amqp1_0_link_util:queue_address(QueueName)}},
                     Link#outgoing_link{queue = QueueName}};
                _Else ->
                    {error, {both_dynamic_and_address_supplied,
                             Dynamic, Address}}
            end;
        _ ->
            case Address of
                {Enc, Destination}
                  when Enc =:= utf8 ->
                    case rabbit_amqp1_0_link_util:parse_destination(Destination, Enc) of
                        ["queue", Name] ->
                            case rabbit_amqp1_0_link_util:declare_queue(Name, DCh) of
                                {ok, QueueName} ->
                                    {ok, Source,
                                     Link#outgoing_link{queue = QueueName}};
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        ["exchange", Name, RK] ->
                            case rabbit_amqp1_0_link_util:check_exchange(Name, DCh) of
                                {ok, ExchangeName} ->
                                    RoutingKey = list_to_binary(RK),
                                    {ok, QueueName} =
                                        rabbit_amqp1_0_link_util:create_bound_queue(
                                          ExchangeName, RoutingKey, DCh),
                                    {ok, Source, Link#outgoing_link{queue = QueueName}};
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        _Otherwise ->
                            {error, {unknown_address, Address}}
                    end;
                _ ->
                    {error, {unknown_address, Address}}
            end
    end.

delivery(Deliver = #'basic.deliver'{delivery_tag = DeliveryTag,
                                    routing_key  = RKey},
                Msg, FrameMax, Handle, Session,
                #outgoing_link{send_settled = SendSettled,
                               default_outcome = DefaultOutcome}) ->
    DeliveryId = rabbit_amqp1_0_session:next_delivery_id(Session),
    Session1 = rabbit_amqp1_0_session:record_outgoing(
                 DeliveryTag, SendSettled, DefaultOutcome, Session),
    Txfr = #'v1_0.transfer'{handle = Handle,
                            delivery_tag = {binary, <<DeliveryTag:64>>},
                            delivery_id = {uint, DeliveryId},
                            %% The only one in AMQP 1-0
                            message_format = {uint, 0},
                            settled = SendSettled,
                            resume = false,
                            more = false,
                            aborted = false,
                            %% TODO: actually batchable would be fine,
                            %% but in any case it's only a hint
                            batchable = false},
    Msg1_0 = rabbit_amqp1_0_message:annotated_message(
               RKey, Deliver, Msg),
    ?DEBUG("Outbound content:~n  ~p~n",
           [[rabbit_amqp1_0_framing:pprint(Section) ||
                Section <- rabbit_amqp1_0_framing:decode_bin(
                             iolist_to_binary(Msg1_0))]]),
    %% TODO Ugh
    TLen = iolist_size(rabbit_amqp1_0_framing:encode_bin(Txfr)),
    Frames = case FrameMax of
                 unlimited ->
                     [[Txfr, Msg1_0]];
                 _ ->
                     encode_frames(Txfr, Msg1_0, FrameMax - TLen, [])
             end,
    {ok, Frames, Session1}.

encode_frames(T, Msg, MaxContentLen, Transfers) ->
    case iolist_size(Msg) > MaxContentLen of
        true  ->
            <<Chunk:MaxContentLen/binary, Rest/binary>> =
                iolist_to_binary(Msg),
            T1 = T#'v1_0.transfer'{more = true},
            encode_frames(T, Rest, MaxContentLen,
                          [[T1, Chunk] | Transfers]);
        false ->
            lists:reverse([[T, Msg] | Transfers])
    end.

transfered(DeliveryTag, Channel,
           Link = #outgoing_link{ delivery_count = Count,
                                  send_settled   = SendSettled }) ->
    if SendSettled ->
            amqp_channel:cast(Channel,
                              #'basic.ack'{ delivery_tag = DeliveryTag });
       true ->
            ok
    end,
    Link#outgoing_link{delivery_count = serial_add(Count, 1)}.
