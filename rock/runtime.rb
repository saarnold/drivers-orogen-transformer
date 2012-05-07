# This file contains runtime support for orocos.rb, specific to the transformer
# It gets loaded by orocos.rb whenever an extension called "transformer" is
# found on one of the oroGen task models

module Transformer
    # Module used to add port-frame declarations on ports
    module PortExtension
        attr_accessor :frame
    end

    # Module used to hook the Roby find-path mechanisms into the
    # transformer's loading mechanisms
    module BundleLoadMechanismOverride
        def load(*conf)
            args = conf + [:order => :specific_first]
            file = Roby.app.find_file(*args)
            if !file
                raise ArgumentError, "cannot find #{conf.join("/")} in the Roby application path"
            end
            super(file)
        end
    end

    def self.use_bundle_loader
        Orocos.transformer.manager.conf.extend BundleLoadMechanismOverride
    end

    # Transformer setup for ruby scripts
    class RuntimeSetup
        attr_reader :manager
        attr_reader :configuration_state

        def broadcaster
            @broadcaster || Transformer.broadcaster
        end

        def initialize
            Orocos.load_typekit('transformer')
            @configuration_state = Types::Transformer::ConfigurationState.new
            @manager = Transformer::TransformationManager.new
        end

        # Load a transformer configuration file
        def load_conf(*path)
            manager.load_configuration(*path)
        end

        # Do configuration on the provided tasks. It will use the configuration
        # stored in \c config to create the needed connections for dynamic
        # transformations
        def setup(*tasks)
            tasks.each do |t|
                setup_task(t)
            end

            if broadcaster
                publish(*tasks)
            end
        end

        class InvalidTransformProducer < RuntimeError
            attr_reader :dyn
            def initialize(dyn)
                @dyn = dyn
            end

            def pretty_print(pp)
                pp.text "invalid producer declaration #{dyn.from} => #{dyn.to} by #{dyn.producer}: #{message}"
            end
        end

        # Given a task, find an output port that can be used as a transformation
        # provider
        def resolve_producer(dyn)
            producer_name, producer_port_name = dyn.producer.split('.')
            producer_task =
                begin Orocos::TaskContext.get(producer_name)
                rescue Orocos::NotFound
                    Transformer.warn "#{producer_name}, which is registered as the producer of #{dyn.from} => #{dyn.to}, cannot be contacted"
                    raise
                end

            if producer_port_name
                begin
                    return producer_task.port(producer_port_name)
                rescue Orocos::NotFound
                    Transformer.warn "#{producer_name}.#{producer_port_name}, which is registered as the producer of #{dyn.from} => #{dyn.to}, does not exist on #{producer_task.name} (#{producer_task.model.name})"
                    raise
                end
            else
                candidates = producer_task.enum_for(:each_output_port).find_all do |p|
                    p.orocos_type_name == "/base/samples/RigidBodyState"
                end
                if candidates.empty?
                    raise InvalidTransformProducer.new(dyn), "found no RigidBodyState port on #{producer_name}, declared as the producer of #{dyn.from} => #{dyn.to}"
                elsif candidates.size > 1
                    raise InvalidTransformProducer.new(dyn), "more than one RigidBodyState port found on #{producer_name}: #{candidates.map(&:name).sort.join(", ")}, specify the producer of #{dyn.from} => #{dyn.to} as task_name.port_name"
                end
                return candidates.first
            end
        end

        class UnknownFrame < RuntimeError; end

        def setup_task(task, policy = { :type => :buffer, :size => 100 })
            return if !task.model.has_transformer?

            tr = task.model.transformer

            needed_producers = Hash.new
            needed_static_transforms = Hash.new
            tr.each_needed_transformation do |trsf|
                from = task.property("#{trsf.from}_frame").read
                to   = task.property("#{trsf.to}_frame").read
                if from.empty?
                    raise NoSelectedFrame, "frame #{trsf.from} has not been selected on #{task.name}"
                elsif to.empty?
                    raise NoSelectedFrame, "frame #{trsf.to} has not been selected on #{task.name}"
                elsif !manager.conf.has_frame?(from)
                    raise UnknownFrame, "frame #{from}, selected on #{task.name} for #{trsf.from}, does not exist"
                elsif !manager.conf.has_frame?(to)
                    raise UnknownFrame, "frame #{to}, selected on #{task.name} for #{trsf.to}, does not exist"
                end

                Transformer.debug do
                    Transformer.debug "looking for chain for #{from} => #{to} in #{task.name}"
                end
                chain =
		    begin manager.transformation_chain(from, to)
		    rescue Transformer::TransformationNotFound => e
			raise e, "#{e.message}, required by #{task.name} for #{trsf.from} => #{trsf.to}"
		    end
                Transformer.log_pp(:debug, chain)

                static, dynamic = chain.partition
                Transformer.debug do
                    Transformer.debug "#{static.size} static transformations"
                    Transformer.debug "#{dynamic.size} dynamic transformations"
                    break
                end

                static.each do |sta|
                    needed_static_transforms[[sta.from, sta.to]] = sta
                end
                dynamic.each do |dyn|
                    producer_port = resolve_producer(dyn)
                    needed_producers[[producer_port.task.name, producer_port.name]] ||= producer_port
                end
            end

            task.static_transformations = needed_static_transforms.each_value.map do |static|
                rbs = Types::Base::Samples::RigidBodyState.invalid
                rbs.sourceFrame = static.from
                rbs.targetFrame = static.to
                rbs.position = static.translation
                rbs.orientation = static.rotation
                rbs
            end
            dynamic_transforms_port = task.port('dynamic_transformations')
            needed_producers.each_value do |out_port|
                out_port.connect_to(dynamic_transforms_port, policy)
            end
        end

        def reset_configuration_state
            configuration_state.port_transformation_associations.clear
            configuration_state.port_frame_associations.clear
            configuration_state.static_transformations.clear
        end

        def update_static_state
            configuration_state.static_transformations =
                manager.conf.
                    enum_for(:each_static_transform).map do |static|
                        rbs = Types::Base::Samples::RigidBodyState.invalid
                        rbs.sourceFrame = static.from
                        rbs.targetFrame = static.to
                        rbs.position = static.translation
                        rbs.orientation = static.rotation
                        rbs
                    end
        end

        def update_configuration_state(*tasks)
            update_static_state

            # NOTE: the port-transform associations that are needed to connect
            # to the producers have already been filled by #setup_task. Do the
            # rest.
            manager.conf.each_dynamic_transform do |dyn|
                begin
                    producer_port = resolve_producer(dyn)
                    configuration_state.port_transformation_associations <<
                        Types::Transformer::PortTransformationAssociation.new(:task => producer_port.task.name, :port => producer_port.name,
                                                                         :from_frame => dyn.from, :to_frame => dyn.to)
                rescue Orocos::NotFound
                end
            end

            tasks.each do |task|
                task.each_input_port do |p|
                    if p.frame
                        configuration_state.port_frame_associations <<
                            Types::Transformer::PortFrameAssociation.new(:task => task.name, :port => p.name, :frame => p.frame)
                    end
                end
                task.each_output_port do |p|
                    if p.frame
                        configuration_state.port_frame_associations <<
                            Types::Transformer::PortFrameAssociation.new(:task => task.name, :port => p.name, :frame => p.frame)
                    end
                end
            end

        end

        def publish(*tasks)
            reset_configuration_state
            update_configuration_state(*tasks)

            # Make sure the component is running
            if !broadcaster.running?
                broadcaster.start
            end
            broadcaster.setConfiguration(configuration_state)
        end

        def start_broadcaster(name = Transformer.broadcaster_name, options = Hash.new)
            options = options.merge('transformer::Task' => name)
            Orocos::Process.run(options) do
                @broadcaster = Orocos::TaskContext.get(name)
                yield
            end
        end
    end

    class << self
        # If Transformer.broadcaster is not set, this is the name of the
        # transformer::Task task that should be started to publish the
        # transformer configuration
        #
        # Set to nil to not publish the transformer configuration at all
        #
        # It defaults to "transformer_broadcaster"
        attr_accessor :broadcaster_name

        # If set, the transformer setup will use the task stored here instead of
        # starting its own
        attr_accessor :broadcaster
    end
    @broadcaster_name = 'transformer_broadcaster'
end

module Orocos
    def self.transformer
        @transformer ||= ::Transformer::RuntimeSetup.new
    end

    class InputPort
        include ::Transformer::PortExtension
    end

    class OutputPort
        include ::Transformer::PortExtension
    end
end
