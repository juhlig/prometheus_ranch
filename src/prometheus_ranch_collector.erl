%% Copyright (c) 2020, Jan Uhlig <j.uhlig@mailingwork.de>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(prometheus_ranch_collector).

-behavior(prometheus_collector).

-export([deregister_cleanup/1]).
-export([collect_mf/2]).

-include_lib("prometheus/include/prometheus.hrl").

-define(METRIC_NAME_PREFIX, "ranch_").

%% --- API ---

-spec deregister_cleanup(_) -> ok.
deregister_cleanup(_) -> ok.

-spec collect_mf(_, prometheus_collector:collect_mf_callback()) -> ok.
collect_mf(_Registry, Callback) ->
	Metrics = metrics(),
	EnabledMetrics = enabled_metrics(),
	_ = [add_metric_family(Metric, Callback) ||
		{Name, _, _, _} = Metric <- Metrics,
		metric_enabled(Name, EnabledMetrics)],
	ok.

%% --- INTERNAL ---

-type listener() :: {ranch:ref(), pid()}.
-type metrics() :: #{atom() => {gauge | counter, [prometheus_model:'Metric'()]}}.
-type labels() :: [{atom(), term()}].

add_metric_family({Name, Type, Help, Metrics}, Callback) ->
	Callback(prometheus_model_helpers:create_mf(?METRIC_NAME(Name), Help, Type, Metrics)).

%% Prometheus metric name for a ranch metric.
-spec name(atom()) -> atom().
name(acceptors) ->
	num_acceptors;
name(acceptors_config) ->
	num_acceptors_config;
name(conns_sups) ->
	num_conns_sups;
name(conns_sups_config) ->
	num_conns_sups_config;
name(listen_sockets_config) ->
	num_listen_sockets_config;
name(connections) ->
	num_connections;
name(active_connections) ->
	num_active_connections;
name(memory) ->
	proc_memory_bytes;
name(heap_size) ->
	proc_heap_size_bytes;
name(min_heap_size) ->
	proc_min_heap_size_bytes;
name(min_bin_vheap_size) ->
	proc_min_bin_vheap_size_bytes;
name(stack_size) ->
	proc_stack_size_bytes;
name(total_heap_size) ->
	proc_total_heap_size_bytes;
name(message_queue_len) ->
	proc_message_queue_len;
name(reductions) ->
	proc_reductions;
name(status) ->
	proc_status;
name(accepted_connections) ->
	num_accepted_connections;
name(terminated_connections) ->
	num_terminated_connections;
name(Name) ->
	Name.

%% Prometheus metric help for a ranch metric.
-spec help(atom()) -> string().
help(acceptors) ->
	"The number of acceptors.";
help(acceptors_config) ->
	"The configured number of acceptors.";
help(conns_sups) ->
	"The number of connection supervisors.";
help(conns_sups_config) ->
	"The configured number of connection supervisors.";
help(listen_sockets_config) ->
	"The configured number of listen sockets.";
help(connections) ->
	"The number of connection processes.";
help(active_connections) ->
	"The number of active connection processes.";
help(memory) ->
	"The size in bytes of the process. This includes call stack, heap, and internal structures.";
help(heap_size) ->
	"The size in bytes of the youngest heap generation of the process. "
	"This generation includes the process stack. This information is "
	"highly implementation-dependent, and can change if the implementation changes.";
help(min_heap_size) ->
	"The minimum heap size, in bytes, for the process.";
help(min_bin_vheap_size) ->
	"The minimum binary virtual heap size, in bytes, for the process.";
help(stack_size) ->
	"The stack size, in bytes, of the process.";
help(total_heap_size) ->
	"The total size, in bytes, of all heap fragments of the process. "
	"This includes the process stack and any unreceived messages that "
	"are considered to be part of the heap.";
help(message_queue_len) ->
	"The number of messages currently in the message queue of the process.";
help(reductions) ->
	"The number of reductions executed by the process.";
help(status) ->
	"The current status of the distribution process. "
	"The status is represented as a numerical value where `exiting=1', "
	"`suspended=2', `runnable=3', `garbage_collecting=4', `running=5' "
	"and `waiting=6'.";
help(accepted_connections) ->
	"The number of connections accepted.";
help(terminated_connections) ->
	"The number of connections terminated.";
help(_) ->
	"".

%% Metrics for all listeners.
-spec ranch_metrics() -> metrics().
ranch_metrics() ->
	Listeners = ranch_server:get_listener_sups(),
	ranch_metrics(Listeners, #{}).

-spec ranch_metrics([{ranch:ref(), pid()}], metrics()) -> metrics().
ranch_metrics([], Acc) ->
	Acc;
ranch_metrics([{Ref, Pid}|Listeners], Acc0) ->
	Acc1 = listener_metrics({Ref, Pid}, [{listener, Ref}], Acc0),
	ranch_metrics(Listeners, Acc1).

%% Metrics for an individual listener.
-spec listener_metrics(listener(), labels(), metrics()) -> metrics().
listener_metrics(Listener={_, Pid}, Labels, Acc0) ->
	Children = supervisor:which_children(Pid),
	{ranch_conns_sup_sup, ConnsSupSup, supervisor, _} = lists:keyfind(ranch_conns_sup_sup, 1, Children),
	Acc1 = conns_sup_sup_metrics(Listener, ConnsSupSup, Labels, Acc0),
	{ranch_acceptors_sup, AcceptorsSup, supervisor, _} = lists:keyfind(ranch_acceptors_sup, 1, Children),
	Acc2 = case AcceptorsSup of
		undefined -> Acc1;
		_ -> acceptors_sup_metrics(Listener, AcceptorsSup, Labels, Acc1)
	end,
	config_metrics(Listener, Labels, Acc2).

%% Metrics for configuration values of a listener.
-spec config_metrics(listener(), labels(), metrics()) -> metrics().
config_metrics({Ref, _}, Labels, Acc) ->
	Info = ranch:info(Ref),
	TransOpts = maps:get(transport_options, Info, #{}),

	NumLSocks = maps:get(num_listen_sockets, TransOpts, 1),
	NumAcceptors = maps:get(num_acceptors, TransOpts, 10),
	NumConnsSups = maps:get(num_conns_sups, TransOpts, NumAcceptors),
	update_metrics(
		Labels,
		[
			{gauge, listen_sockets_config, NumLSocks},
			{gauge, acceptors_config, NumAcceptors},
			{gauge, conns_sups_config, NumConnsSups}
		],
		Acc
	).

%% Metrics for a listener's conns_sup_sup.
-spec conns_sup_sup_metrics(listener(), pid(), labels(), metrics()) -> metrics().
conns_sup_sup_metrics(Listener, ConnsSupSup, Labels, Acc0) ->
	ConnsSups = [{Id, Pid} || {{ranch_conns_sup, Id}, Pid, supervisor, _} <- supervisor:which_children(ConnsSupSup), is_pid(Pid)],
	Acc1 = conns_sup_metrics(Listener, ConnsSups, [{type, conns_sup}|Labels], Acc0),
	update_metrics(Labels, [{gauge, conns_sups, length(ConnsSups)}], Acc1).

%% Metrics for an individual conn_sup.
-spec conns_sup_metrics(listener(), [{term(), pid()}], labels(), metrics()) -> metrics().
conns_sup_metrics({Ref, _}, ConnsSups, Labels, Acc0) ->
	Acc1 = sup_metrics(ConnsSups, Labels, Acc0),
	ConnCounts = maps:get(metrics, ranch:info(Ref), #{}),
	lists:foldl(
		fun ({Id, Pid}, Acc2) ->
			Labels1 = [{pid, Pid}, {id, Id}|Labels],
			Counts = supervisor:count_children(Pid),
			NSups = proplists:get_value(supervisors, Counts, 0),
			NWorkers = proplists:get_value(workers, Counts, 0),
			NActive = ranch_conns_sup:active_connections(Pid),
			NAccepted = maps:get({conns_sup, Id, accept}, ConnCounts, undefined),
			NTerminated = maps:get({conns_sup, Id, terminate}, ConnCounts, undefined),
			update_metrics(
				Labels1,
				[
					{gauge, connections, NSups + NWorkers},
					{gauge, active_connections, NActive},
					{counter, accepted_connections, NAccepted},
					{counter, terminated_connections, NTerminated}
				],
				Acc2
			)
		end,
		Acc1,
		ConnsSups
	).

%% Metrics for a listener's acceptors_sup.
-spec acceptors_sup_metrics(listener(), pid(), labels(), metrics()) -> metrics().
acceptors_sup_metrics(_Listener, AcceptorsSup, Labels, Acc0) ->
	Acceptors = [{Id, Pid} || {{acceptor, _, Id}, Pid, worker, _} <- supervisor:which_children(AcceptorsSup), is_pid(Pid)],
	Acc1 = sup_metrics(Acceptors, [{type, acceptor}|Labels], Acc0),
	Counts = supervisor:count_children(AcceptorsSup),
	N = proplists:get_value(workers, Counts, 0),
	update_metrics([{type, acceptors_sup}, {pid, AcceptorsSup}|Labels], [{gauge, acceptors, N}], Acc1).

%% Metrics for a generic supervisor.
-spec sup_metrics([{term(), pid()}], labels(), metrics()) -> metrics().
sup_metrics([], _, Acc) ->
	Acc;
sup_metrics([{Id, Pid}|Sups], Labels, Acc0) ->
	Labels1 = [{id, Id}, {pid, Pid}|Labels],
	Acc1 = proc_metrics(Pid, Labels1, Acc0),
	sup_metrics(Sups, Labels, Acc1).

%% Process metrics.
-spec proc_metrics(pid(), list(), metrics()) -> metrics().
proc_metrics(Pid, Labels, Acc) ->
	Stats = process_info(Pid, [memory, heap_size, min_heap_size, min_bin_vheap_size, stack_size, total_heap_size, message_queue_len, reductions, status]),
	update_metrics(Labels, [{gauge, Key, convert_proc_value(Key, Value)} || {Key, Value} <- Stats], Acc).

%% Convert the value of a process metric.
-spec convert_proc_value(atom(), term()) -> number().
convert_proc_value(heap_size, Value) -> 2*Value;
convert_proc_value(min_heap_size, Value) -> 2*Value;
convert_proc_value(min_bin_vheap_size, Value) -> 2*Value;
convert_proc_value(stack_size, Value) -> 2*Value;
convert_proc_value(total_heap_size, Value) -> 2*Value;
convert_proc_value(status, exiting) -> 1;
convert_proc_value(status, suspended) -> 2;
convert_proc_value(status, runnable) -> 3;
convert_proc_value(status, garbage_collecting) -> 4;
convert_proc_value(status, running) -> 5;
convert_proc_value(status, waiting) -> 6;
convert_proc_value(_, Value) -> Value.

%% Update the metrics collection with a new metric.
-spec update_metrics(labels(), [{gauge | counter, atom(), number() | undefined | infinity}], metrics()) -> metrics().
update_metrics(Labels, RawMetrics, Coll) ->
	lists:foldl(
		fun
			({Type, Name, undefined}, Acc) ->
				maps:update_with(Name, fun (Old) -> Old end, {Type, []}, Acc);
			({gauge, Name, Value}, Acc) ->
				NewMetric = prometheus_model_helpers:gauge_metric(Labels, Value),
				maps:update_with(Name, fun ({gauge, OldMetrics}) -> {gauge, [NewMetric|OldMetrics]} end, {gauge, [NewMetric]}, Acc);
			({counter, Name, Value}, Acc) ->
				NewMetric = prometheus_model_helpers:counter_metric(Labels, Value),
				maps:update_with(Name, fun ({counter, OldMetrics}) -> {counter, [NewMetric|OldMetrics]} end, {counter, [NewMetric]}, Acc)
		end,
		Coll,
		RawMetrics
	).

%% Prometheus metrics from a metrics collection.
-spec metrics() -> [{atom(), atom(), string(), [prometheus_model:'Metric'()]}].
metrics() ->
	maps:fold(
		fun
			(Key, {Type, Metrics}, Acc) ->
				[{name(Key), Type, help(Key), Metrics}|Acc]
		end,
		[],
		ranch_metrics()
	).

%% Enabled metrics from application environment.
-spec enabled_metrics() -> all | [atom()].
enabled_metrics() ->
	application:get_env(prometheus, ranch_collector_metrics, all).

%% Return if a specific metric is enabled.
-spec metric_enabled(atom(), all | [atom()]) -> boolean().
metric_enabled(_Name, all) ->
	true;
metric_enabled(Name, EnabledMetrics) ->
	lists:member(Name, EnabledMetrics).

