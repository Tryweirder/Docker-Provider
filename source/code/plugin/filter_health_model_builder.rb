# Copyright (c) Microsoft Corporation.  All rights reserved.

# frozen_string_literal: true

module Fluent
    require 'logger'
    require 'json'
    Dir[File.join(__dir__, './health', '*.rb')].each { |file| require file }


    class FilterHealthModelBuilder < Filter
        Fluent::Plugin.register_filter('filter_health_model_builder', self)

        config_param :enable_log, :integer, :default => 0
        config_param :log_path, :string, :default => '/var/opt/microsoft/docker-cimprov/log/filter_health_model_builder.log'
        config_param :model_definition_path, :default => '/etc/opt/microsoft/docker-cimprov/health/health_model_definition.json'
        config_param :health_monitor_config_path, :default => '/etc/opt/microsoft/docker-cimprov/health/healthmonitorconfig.json'
        config_param :health_state_serialized_path, :default => '/mnt/azure/health_model_state.json'
        attr_reader :buffer, :model_builder, :health_model_definition, :monitor_factory, :state_finalizers, :monitor_set, :model_builder, :hierarchy_builder, :resources, :kube_api_down_handler, :provider, :reducer, :state, :generator
        include HealthModel

        @@rewrite_tag = 'oms.api.KubeHealth.Signals'
        @@cluster_id = KubernetesApiClient.getClusterId
        @@token_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        @@cert_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        @@cluster_health_model_enabled = HealthMonitorUtils.is_cluster_health_model_enabled

        def initialize
            begin
                super
                @buffer = HealthModel::HealthModelBuffer.new
                @cluster_health_state = ClusterHealthState.new(@@token_file_path, @@cert_file_path)
                @health_model_definition = HealthModel::ParentMonitorProvider.new(HealthModel::HealthModelDefinitionParser.new(@model_definition_path).parse_file)
                @monitor_factory = HealthModel::MonitorFactory.new
                @hierarchy_builder = HealthHierarchyBuilder.new(@health_model_definition, @monitor_factory)
                # TODO: Figure out if we need to add NodeMonitorHierarchyReducer to the list of finalizers. For now, dont compress/optimize, since it becomes impossible to construct the model on the UX side
                @state_finalizers = [HealthModel::AggregateMonitorStateFinalizer.new]
                @monitor_set = HealthModel::MonitorSet.new
                @model_builder = HealthModel::HealthModelBuilder.new(@hierarchy_builder, @state_finalizers, @monitor_set)
                @kube_api_down_handler = HealthKubeApiDownHandler.new
                @resources = HealthKubernetesResources.instance
                @reducer = HealthSignalReducer.new
                @state = HealthMonitorState.new
                @generator = HealthMissingSignalGenerator.new
                #TODO: cluster_labels needs to be initialized
                @provider = HealthMonitorProvider.new(@@cluster_id, HealthMonitorUtils.get_cluster_labels, @resources, @health_monitor_config_path)
                deserialized_state_info = @cluster_health_state.get_state
                @state = HealthMonitorState.new
                @state.initialize_state(deserialized_state_info)
                @cluster_old_state = 'none'
                @cluster_new_state = 'none'
            rescue => e
                ApplicationInsightsUtility.sendExceptionTelemetry(e, {"FeatureArea" => "Health"})
            end
        end

        def configure(conf)
            begin
                super
                @log = nil
                if @enable_log
                    @log = Logger.new(@log_path, 'weekly')
                    @log.info 'Starting filter_health_model_builder plugin'
                end
            rescue => e
                ApplicationInsightsUtility.sendExceptionTelemetry(e, {"FeatureArea" => "Health"})
            end
        end

        def start
            super
        end

        def shutdown
            super
        end

        def filter_stream(tag, es)
            begin
                if !@@cluster_health_model_enabled
                    @log.info "Cluster Health Model disabled in filter_health_model_builder"
                    MultiEventStream.new
                end
                new_es = MultiEventStream.new
                time = Time.now

                if tag.start_with?("oms.api.KubeHealth.DaemonSet.Node")
                    node_records = []
                    if !es.nil?
                        es.each{|time, record|
                            node_records.push(record)
                        }
                        @buffer.add_to_buffer(node_records)
                    end
                    return MultiEventStream.new
                elsif tag.start_with?("oms.api.KubeHealth.DaemonSet.Container")
                    container_records = []
                    if !es.nil?
                        es.each{|time, record|
                            container_records.push(record)
                        }
                    end
                    container_records_aggregator = HealthContainerCpuMemoryAggregator.new(@resources, @provider)
                    deduped_records = container_records_aggregator.dedupe_records(container_records)
                    container_records_aggregator.aggregate(deduped_records)
                    container_records_aggregator.compute_state
                    container_cpu_memory_records = container_records_aggregator.get_records
                    @buffer.add_to_buffer(container_cpu_memory_records)
                    return MultiEventStream.new
                elsif tag.start_with?("oms.api.KubeHealth.ReplicaSet")
                    records = []
                    es.each{|time, record|
                        records.push(record)
                    }
                    @buffer.add_to_buffer(records)
                    records_to_process = @buffer.get_buffer
                    @buffer.reset_buffer

                    health_monitor_records = []
                    records_to_process.each do |record|
                        monitor_instance_id = record[HealthMonitorRecordFields::MONITOR_INSTANCE_ID]
                        monitor_id = record[HealthMonitorRecordFields::MONITOR_ID]
                        #HealthMonitorRecord
                        health_monitor_record = HealthMonitorRecord.new(
                            record[HealthMonitorRecordFields::MONITOR_ID],
                            record[HealthMonitorRecordFields::MONITOR_INSTANCE_ID],
                            record[HealthMonitorRecordFields::TIME_FIRST_OBSERVED],
                            record[HealthMonitorRecordFields::DETAILS]["state"],
                            @provider.get_labels(record),
                            @provider.get_config(monitor_id),
                            record[HealthMonitorRecordFields::DETAILS]
                        )
                        health_monitor_records.push(health_monitor_record)
                        #puts "#{monitor_instance_id} #{instance_state.new_state} #{instance_state.old_state} #{instance_state.should_send}"
                    end

                    @log.info "health_monitor_records.size #{health_monitor_records.size}"
                    # Dedupe daemonset signals
                    # Remove unit monitor signals for “gone” objects
                    # update state for the reduced set of signals
                    reduced_records = @reducer.reduce_signals(health_monitor_records, @resources)
                    reduced_records.each{|record|
                        @state.update_state(record,
                            @provider.get_config(record.monitor_id)
                            )
                        # get the health state based on the monitor's operational state
                        # update state calls updates the state of the monitor based on configuration and history of the the monitor records
                        record.state = @state.get_state(record.monitor_instance_id).new_state
                    }
                    @log.info "after deduping and removing gone objects reduced_records.size #{reduced_records.size}"

                    reduced_records = @kube_api_down_handler.handle_kube_api_down(reduced_records)
                    @log.info "after kube api down handler health_monitor_records.size #{health_monitor_records.size}"

                    #get the list of  'none' and 'unknown' signals
                    missing_signals = @generator.get_missing_signals(@@cluster_id, reduced_records, @resources, @provider)

                    @log.info "after getting missing signals missing_signals.size #{missing_signals.size}"
                    #update state for missing signals
                    missing_signals.each{|signal|

                        @state.update_state(signal, @provider.get_config(signal.monitor_id))
                        @log.info "After Updating #{@state.get_state(signal.monitor_instance_id)} #{@state.get_state(signal.monitor_instance_id).new_state}"
                        # for unknown/none records, update the "monitor state" to be the latest state (new_state) of the monitor instance from the state
                        signal.state = @state.get_state(signal.monitor_instance_id).new_state
                    }

                    @generator.update_last_received_records(reduced_records)
                    all_records = reduced_records.clone
                    all_records.push(*missing_signals)

                    @log.info "after Adding missing signals all_records.size #{all_records.size}"

                    # build the health model
                    @model_builder.process_records(all_records)
                    all_monitors = @model_builder.finalize_model

                    @log.info "after building health_model #{all_monitors.size}"

                    # update the state for aggregate monitors (unit monitors are updated above)
                    all_monitors.each{|monitor_instance_id, monitor|
                        if monitor.is_aggregate_monitor
                            @state.update_state(monitor,
                                @provider.get_config(monitor.monitor_id)
                                )
                        end

                        instance_state = @state.get_state(monitor_instance_id)
                        #puts "#{monitor_instance_id} #{instance_state.new_state} #{instance_state.old_state} #{instance_state.should_send}"
                        should_send = instance_state.should_send

                        # always send cluster monitor as a heartbeat
                        if !should_send && monitor_instance_id != MonitorId::CLUSTER
                            all_monitors.delete(monitor_instance_id)
                        end
                    }

                    @log.info "after optimizing health signals all_monitors.size #{all_monitors.size}"

                    current_time = Time.now
                    emit_time = current_time.to_f
                    # for each key in monitor.keys,
                    # get the state from health_monitor_state
                    # generate the record to send
                    all_monitors.keys.each{|key|
                        record = @provider.get_record(all_monitors[key], state)
                        if record[HealthMonitorRecordFields::MONITOR_ID] == MonitorId::CLUSTER
                            if !record[HealthMonitorRecordFields::DETAILS].nil?
                                details = JSON.parse(record[HealthMonitorRecordFields::DETAILS])
                                details[HealthMonitorRecordFields::HEALTH_MODEL_DEFINITION_VERSION] = "#{ENV['HEALTH_MODEL_DEFINITION_VERSION']}"
                                record[HealthMonitorRecordFields::DETAILS] = details.to_json
                            end
                            if all_monitors.size > 1
                                old_state = record[HealthMonitorRecordFields::OLD_STATE]
                                new_state = record[HealthMonitorRecordFields::NEW_STATE]
                                if old_state != new_state && @cluster_old_state != old_state && @cluster_new_state != new_state
                                        ApplicationInsightsUtility.sendCustomEvent("HealthModel_ClusterStateChanged",{"old_state" => old_state , "new_state" => new_state, "monitor_count" => all_monitors.size})
                                        @log.info "sent telemetry for cluster state change from #{record['OldState']} to #{record['NewState']}"
                                        @cluster_old_state = old_state
                                        @cluster_new_state = new_state
                                end
                            end
                        end
                        record_wrapper = {
                            "DataType" => "KUBE_HEALTH_BLOB",
                            "IPName" => "ContainerInsights",
                            "DataItems" => [record.each { |k, v| record[k] = v }],
                        }
                        new_es.add(emit_time, record_wrapper)
                    }

                    #emit the stream
                    router.emit_stream(@@rewrite_tag, new_es)

                    #initialize monitor_set and model_builder
                    @monitor_set = HealthModel::MonitorSet.new
                    @model_builder = HealthModel::HealthModelBuilder.new(@hierarchy_builder, @state_finalizers, @monitor_set)

                    #update cluster state custom resource
                    @cluster_health_state.update_state(@state.to_h)

                    # return an empty event stream, else the match will throw a NoMethodError
                    return MultiEventStream.new
                elsif tag.start_with?("oms.api.KubeHealth.Signals")
                    # this filter also acts as a pass through as we are rewriting the tag and emitting to the fluent stream
                    es
                else
                    raise 'Invalid tag #{tag} received'
                end

            rescue => e
                 ApplicationInsightsUtility.sendExceptionTelemetry(e, {"FeatureArea" => "Health"})
                 @log.warn "Message: #{e.message} Backtrace: #{e.backtrace}"
                 return nil
            end
        end
    end
end
