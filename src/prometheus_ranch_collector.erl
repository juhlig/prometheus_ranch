-module(prometheus_ranch_collector).

-export([deregister_cleanup/1]).
-export([collect_mf/2]).

-import(prometheus_model_helpers, [create_mf/4]).

-include_lib("prometheus/include/prometheus.hrl").

-behavior(prometheus_collector).

-define(METRIC_NAME_PREFIX, "ranch_").

deregister_cleanup(_) -> ok.

collect_mf(_Registry, Callback) ->
	Metrics = metrics(),
	EnabledMetrics = enabled_metrics(),
	_ = [add_metric_family(Metric, Callback) ||
		{Name, _, _, _} = Metric <- Metrics,
		metric_enabled(Name, EnabledMetrics)],
	ok.

add_metric_family({Name, Type, Help, Metrics}, Callback) ->
	Callback(create_mf(?METRIC_NAME(Name), Help, Type, Metrics)).

name(acceptors) ->
	num_acceptors;
name(connections) ->
	num_connections;
name(memory) ->
	proc_memory;
name(heap_size) ->
	proc_heap_size_words;
name(min_heap_size) ->
	proc_min_heap_size_words;
name(min_bin_vheap_size) ->
	proc_min_bin_vheap_size_words;
name(stack_size) ->
	proc_stack_size_words;
name(total_heap_size) ->
	proc_total_heap_size_words;
name(message_queue_len) ->
	proc_message_queue_len;
name(reductions) ->
	proc_reductions;
name(status) ->
	proc_status;
name(Name) ->
	Name.

help(acceptors) ->
	"The number of acceptors.";
help(connections) ->
	"The number of connection processes.";
help(memory) ->
	"The size in bytes of the process. This includes call stack, heap, and internal structures.";
help(heap_size) ->
	"The size in words of the youngest heap generation of the process. "
	"This generation includes the process stack. This information is "
	"highly implementation-dependent, and can change if the implementation changes.";
help(min_heap_size) ->
	"The minimum heap size for the process.";
help(min_bin_vheap_size) ->
	"The minimum binary virtual heap size for the process.";
help(stack_size) ->
	"The stack size, in words, of the process.";
help(total_heap_size) ->
	"The total size, in words, of all heap fragments of the process. "
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
help(_) ->
	"".

proc_status_to_int(exiting) -> 1;
proc_status_to_int(suspended) -> 2;
proc_status_to_int(runnable) -> 3;
proc_status_to_int(garbage_collecting) -> 4;
proc_status_to_int(running) -> 5;
proc_status_to_int(waiting) -> 6.

ranch_metrics() ->
	Listeners = ranch_server:get_listener_sups(),
	ranch_metrics(Listeners, #{}).

ranch_metrics([], Acc) ->
	Acc;
ranch_metrics([{Ref, Pid}|Listeners], Acc0) ->
	Acc1 = listener_metrics(Pid, [{listener, Ref}], Acc0),
	ranch_metrics(Listeners, Acc1).

listener_metrics(Pid, Labels, Acc0) ->
	Children = supervisor:which_children(Pid),
	{ranch_conns_sup_sup, ConnsSupSup, supervisor, _} = lists:keyfind(ranch_conns_sup_sup, 1, Children),
	Acc1 = conns_sup_sup_metrics(ConnsSupSup, Labels, Acc0),
	{ranch_acceptors_sup, AcceptorsSup, supervisor, _} = lists:keyfind(ranch_acceptors_sup, 1, Children),
	acceptors_sup_metrics(AcceptorsSup, Labels, Acc1).

conns_sup_sup_metrics(ConnsSupSup, Labels, Acc0) ->
	ConnsSups = [{Id, Pid} || {{ranch_conns_sup, Id}, Pid, supervisor, _} <- supervisor:which_children(ConnsSupSup), is_pid(Pid)],
	conns_sup_metrics(ConnsSups, [{type, conns_sup}|Labels], Acc0).

conns_sup_metrics(ConnsSups, Labels, Acc0) ->
	Acc1 = sup_metrics(ConnsSups, Labels, Acc0),
	lists:foldl(
		fun
			({Id, Pid}, Acc2) ->
				Counts = supervisor:count_children(Pid),
				NSups = proplists:get_value(supervisors, Counts, 0),
				NWorkers = proplists:get_value(workers, Counts, 0),
				Metric = prometheus_model_helpers:gauge_metric([{id, Id}, {pid, Pid}|Labels], NSups + NWorkers),
				maps:update_with(connections, fun (Old) -> [Metric|Old] end, [Metric], Acc2)
		end,
		Acc1,
		ConnsSups
	).

acceptors_sup_metrics(AcceptorsSup, Labels, Acc0) ->
	Acceptors = [{Id, Pid} || {{acceptor, _, Id}, Pid, worker, _} <- supervisor:which_children(AcceptorsSup), is_pid(Pid)],
	Acc1 = sup_metrics(Acceptors, [{type, acceptor}|Labels], Acc0),
	Counts = supervisor:count_children(AcceptorsSup),
	N = proplists:get_value(workers, Counts, 0),
	Metric = prometheus_model_helpers:gauge_metric([{type, acceptors_sup}, {pid, AcceptorsSup}|Labels], N),
	maps:update_with(acceptors, fun (Old) -> [Metric|Old] end, [Metric], Acc1).

sup_metrics([], _, Acc) ->
	Acc;
sup_metrics([{Id, Pid}|Sups], Labels, Acc0) ->
	Labels1 = [{id, Id}, {pid, Pid}|Labels],
	Acc1 = proc_metrics(Pid, Labels1, Acc0),
	sup_metrics(Sups, Labels, Acc1).

proc_metrics(Pid, Labels, Acc0) ->
	Stats = process_info(Pid, [memory, heap_size, min_heap_size, min_bin_vheap_size, stack_size, total_heap_size, message_queue_len, reductions, status]),
	lists:foldl(
		fun
			({status, Value}, Acc2) ->
				Metric = prometheus_model_helpers:gauge_metric(Labels, proc_status_to_int(Value)),
				maps:update_with(status, fun (Old) -> [Metric|Old] end, [Metric], Acc2);
			({Key, Value}, Acc2) ->
				Metric = prometheus_model_helpers:gauge_metric(Labels, Value),
				maps:update_with(Key, fun (Old) -> [Metric|Old] end, [Metric], Acc2)
		end,
		Acc0,
		Stats
	).

metrics() ->
	maps:fold(
		fun
			(Key, Value, Acc) ->
				[{name(Key), gauge, help(Key), Value}|Acc]
		end,
		[],
		ranch_metrics()
	).

enabled_metrics() ->
	application:get_env(prometheus, ranch_collector_metrics, all).

metric_enabled(_Name, all) ->
	true;
metric_enabled(Name, EnabledMetrics) ->
	lists:member(Name, EnabledMetrics).


