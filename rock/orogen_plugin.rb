require 'aggregator_plugin'
require 'transformer'

module TransformerPlugin
    class Generator
        # Code generation to generate code for the first task class that has a
        # transformer in the task hierarchy
        def generate_root_class(task, config)
	    task.add_base_member("transformer", "_#{config.name}", "transformer::Transformer").
		initializer( "_#{config.name}(#{config.priority})" )
	    task.add_base_member("nextStatusTime", "_nextStatusTime", "base::Time")

	    task.in_base_hook("configure", "
    _#{config.name}.clear();
    _#{config.name}.setTimeout( base::Time::fromSeconds( _transformer_max_latency.value()) );
	    ")	    
	    
            task.add_base_member("transformer_status", "transformerStatus", "transformer::TransformerStatus")
            task.in_base_hook("configure", "    transformerStatus.transformations.clear();")

	    # Read out the properties which contains a vector of static transforms
	    # and push them to the transformer
            task.in_base_hook("configure", "
    std::vector<base::samples::RigidBodyState> const& staticTransforms =
        _static_transformations.set();
     for (size_t i = 0; i < staticTransforms.size(); ++i)
        _#{config.name}.pushStaticTransformation(staticTransforms[i]);")

	    task.in_base_hook("update", "
    base::samples::RigidBodyState dynamicTransform;
    while(_dynamic_transformations.read(dynamicTransform, false) == RTT::NewData) {
	_#{config.name}.pushDynamicTransformation(dynamicTransform);
    }

    const base::Time statusPeriod( base::Time::fromSeconds( _#{config.name}_status_period.value() ) );
    do
    {
	const base::Time curTime(base::Time::now());
	if( curTime > _nextStatusTime )
	{
	    _nextStatusTime = curTime + statusPeriod;
            ::aggregator::StreamAlignerStatus stream_aligner_status = _#{config.name}.getStatus();
            stream_aligner_status.name = getName();
	    _#{config.name}_stream_aligner_status.write(stream_aligner_status);
            _#{config.name}_status.write(_transformer.getTransformerStatus());
	}
    }
    while(_#{config.name}.step());")

	    #unregister in cleanup
	    task.in_base_hook("cleanup", "
    _#{config.name}.clear();")
        end

	def generate(task, config)
            task.project.using_library('transformer', :typekit => true)
            port_listener_ext = task.extension("port_listener", false)

            if !(tr = config.task.superclass.find_extension('transformer')) || !tr.needs_transformer?
                is_root = true
                generate_root_class(task, config)
            end

            base_status_index = config.supercall([], :each_needed_transformation).to_a.size
            task.in_base_hook("configure", "    transformerStatus.transformations.resize(#{base_status_index + config.needed_transformations.size()});")
	    task.add_base_header_code("#include <transformer/Transformer.hpp>", true)
            task.add_base_header_code("#include <aggregator/DetermineSampleTimestamp.hpp>", true)

            needed_transformations = config.needed_transformations.sort_by { |t| [t.from, t.to] }
	    needed_transformations.each_with_index do |t, i|
                # BIG FAT WARNING: the key used here for #add_base_member MUST
                # be lexicographically bigger than "transformer" to make sure
                # that the transformer object is constructed before these
                # members
		task.add_base_member("transformer_transformation", member_name(t), "transformer::Transformation &").
		    initializer("#{member_name(t)}(_#{config.name}.registerTransformation(\"#{t.from}\", \"#{t.to}\"))")
	    end

            # Apply the frame selection from the properties inside the configureHook
            frame_selection = config.available_frames.sort.map do |frame_name|
                if config.configurable?(frame_name)
                    "    _#{config.name}.setFrameMapping(\"#{frame_name}\", _#{frame_name}_frame);"
                end
            end.compact
            task.in_base_hook("configure", frame_selection.join("\n"))

	    config.streams.sort_by(&:name).each do |stream|
		stream_data_type = type_cxxname(task, stream)

		# Pull the data in the update hook
		port_listener_ext.add_port_listener(stream.name) do |sample_name|
                    ### HACK TODO
                    # This needs fixing by annotating opaques (i.e. telling
                    # oroGen that some opaques 'behave as' pointers)
                    time_access =
                        if stream_data_type =~ /ReadOnlyPointer/ then "aggregator::determineTimestamp(*#{sample_name})"
                        else "aggregator::determineTimestamp(#{sample_name})"
                        end

                    "	_#{config.name}.pushData(#{idx_name(stream)}, #{time_access}, #{sample_name});"
		end

		#add variable for index
		task.add_base_member("transformer", idx_name(stream), "int")
		
		#add callbacks
		task.add_user_method("void", callback_name(stream), "const base::Time &ts, const #{stream_data_type} &#{stream.name}_sample").
		body("    throw std::runtime_error(\"Transformer callback for #{stream.name} not implemented\");")

		#register streams at transformer
		task.in_base_hook("configure", "
    {
    const double #{stream.name}Period = _#{stream.name}_period.value();
    #{idx_name(stream)} = _#{config.name}.registerDataStream< #{stream_data_type} >(
		    base::Time::fromSeconds(#{stream.name}Period), boost::bind( &#{task.class_name}Base::#{callback_name(stream)}, this, _1, _2), #{stream.priority}, \"#{stream.name}\");
    }")

		# disable streams in start hook, which are not connected
		task.in_base_hook("start", "
		    if( !_#{stream.name}.connected() ) _#{config.name}.disableStream( #{idx_name(stream)} );")

		#unregister in cleanup
		task.in_base_hook("cleanup", "     _#{config.name}.unregisterDataStream(#{idx_name(stream)});")
	    end
	end

        def member_name(t)
            "_#{t.from}2#{t.to}"
        end

        def idx_name(stream)
            "#{stream.name}_idx_tr"
        end

        def type_cxxname(task, stream)
            port = task.find_port(stream.name)
            if(!port)
                raise "Error trying to register nonexisting port " + name + " to the transformer"
            end
        
            port.type.cxx_name
        end
        
        def callback_name(stream)
            "#{stream.name}TransformerCallback"
        end
    end

    # This class is used to declare and configure a transformer instance, and
    # annotate oroGen components with information related to the transformer
    # configuration.
    #
    # An instance of this extension gets added when #transformer is called on
    # the task context. It can be retrieved with:
    #
    #   transformer = task_model.transformer
    #
    # Or, more generically
    #
    #   transformer = task_model.extension("transformer")
    #
    # The extension manages different type of information:
    #
    # First, transformations that are required by the component's computation
    # can be declared using #transform. To provide those, the extension adds a
    # Transformer instance to the task context and configures it to process both
    # incoming transformation data from a dynamic_transformations port, static
    # transformation from a static_transformations property. It essentially
    # behaves like a stream aligner. The stream of data that need the
    # transformations to be processed should be declared with #align_stream.
    #
    # Second, inputs and outputs that provide or receive separate
    # transformations can be annotated using #transform_input and
    # #transfor_output. These ports are not managed by the plugin at runtime.
    # The declarations are only used by the tooling to automatically configure
    # the transformer, and/or to verify the transformer configuration.
    #
    # Finally, other input and output ports can also be annotated with frames.
    # In this case, the annotation means "this data is expressed in frame X".
    # This information is not used by the oroGen component at runtime. The
    # declarations are only used by the tooling to automatically configure the
    # transformer, and/or to verify the transformer configuration.
    #
    # In general, the frames are managed in two levels:
    #
    #  * frame names are local to the component (i.e., while developping a
    #    component, there is no such thing as a 'world' frame. There is "the
    #    world frame of the odometry component")
    #  * they are then mapped to global frame names at runtime
    #
    # The underlying rationale is that hard-coding a frame "world" in component
    # X is not going to work when X gets integrated in bigger systems where
    # "world" might already have a different meaning (i.e. point to a different
    # frame).
    #
    # However, some legacy components *will* use hard-coded frames.
    # Additionally, some other components might have transformation inputs that
    # allow to change the frames stored in the RigidBodyState data structure.
    # This oroGen extension can handle all these cases.
    #
    #  * a frame is set as "configurable" if there is a "#{frame}_frame"
    #    property (as e.g. world_frame) on the associated component. Such
    #    properties are generated by the extension if #transform is used, and if
    #    #configurable is used on the value returned by #transform_input,
    #    #transform_output and #frame:
    #
    #      transform_input("laser2body").
    #         configurable
    #
    #  * if a transform_input has configurable frames, it is expected that the
    #    component will be using the frame name property instead of the data
    #    given through the port. In effect, the component should act as a
    #    "property renaming" component.
    #
    class Extension < Orocos::Spec::TaskModelExtension
        # Describes a stream that the transformer will align as the stream
        # aligner would
        #
        # When callbacks are called for this stream, it is guaranteed that all
        # transformations declared with #transform are available
	class StreamDescription
            # The stream name
	    attr_reader :name
            # The stream period
	    attr_reader :period
            # The stream period
	    attr_reader :priority

	    def initialize(name, period, priority)
		@name   = name
		@period = period
                @priority = priority
	    end
	end
	
        # A transformation needed by the component computation
        #
        # This structure tells the system that the +from+ => +to+ transformation
        # will be needed at runtime by the component's computation
	class NeededTransformation
            # [String] The transformation source
	    attr_reader :from
            # [String] The transformation target
	    attr_reader :to
	    
	    def initialize(from, to)
		@from = from
		@to = to
	    end
	end

        # A transformation associated with a port
        #
        # This structure tells the system that the input or output data flowing
        # through +port_name+ is associated with the +from+ => +to+
        # transformation.
	class TransformationPort
	    attr_reader :from
	    attr_reader :to
            attr_reader :port_name
	    
	    def initialize(from, to, port_name)
		@from = from
		@to = to
                @port_name = port_name
	    end
	end

        # Proxy class used to allow additional configuration
        class TransformationConfigurationProxy
            # The Extension object in which the configuration is stored
            attr_reader :ext
            # The transformation object that we are proxying
            attr_reader :transform

            def initialize(ext, transform)
                @ext = ext
                @transform = transform
            end

            # Call to mark both the transformation frames as "configurable".
            # The task will then have properties that allow to set the global
            # frame names for each task-level frames.
            def configurable
                ext.configurable_frames(transform.from, transform.to)
            end

            def method_missing(m, *args, &block)
                if transform.respond_to?(m)
                    transform.send(m, *args, &block)
                else super
                end
            end
        end

        def name; "transformer" end
	
        attr_predicate :default?, true

        # The underlying task context
        attr_reader :task

        # The transformer max latency
	dsl_attribute :max_latency do |value|
            Float(value)
        end

        # [Array<StreamDescription>] the list of streams that get aligned by the
        # transformer
	attr_reader :streams
        # [Set<String>] set of available frames
        attr_reader :available_frames
        # [Map<Orocos::Spec::Port, String>] associations between port and
        # frames. See #associate_frame_to_ports
        attr_reader :frame_associations
        # [Map<Orocos::Spec::Port, (String,String)>] associations between port and
        # transformations. See #associate_transform_to_ports
        attr_reader :transform_associations
        # [Array<NeededTransformations> the list of transformations that should
        # be provided by the transformer at runtime
	attr_reader :needed_transformations
        # [Map<Orocos::Spec::InputPort, TransformationPort>] an association between
        # input ports and the transformations they provide. The ports must be of
        # type base/samples/RigidBodyState
        attr_reader :transform_inputs
        # [Map<Orocos::Spec::OutputPort, TransformationPort>] an association between
        # outputs ports and the transformations they provide. The ports must be of
        # type base/samples/RigidBodyState
        attr_reader :transform_outputs
        # [Set<String>] a set of frames for which a configuration property
        # should be added to the component
        attr_reader :configurable_frames
	# [Integer] the priority value which is given to dynamic transformation streams
	attr_reader :priority

	def initialize(name, task)
            super(name)
            @task = task

	    @streams = Array.new()
            @default = true
            @available_frames = Set.new
            @frame_associations = Hash.new
            @transform_associations = Hash.new

	    @needed_transformations = Array.new
            @transform_outputs = Hash.new
            @transform_inputs  = Hash.new

            @configurable_frames = Set.new
            @priority_counter = 0
	    @priority = -10
	end

	# set the priority of the dynamic transformation streams
	def transform_priority( priority )
	    @priority = priority
	end
	
        # Requires the transformer to align the given input port on the
        # transformations
	def align_port(name, period = 0, priority = nil)
            if !task.has_input_port?(name)
                raise ArgumentError, "#{task.name} has no input port called #{name}, cannot align"
            end
            if priority
                streams << StreamDescription.new(name, period, priority)
            else
                streams << StreamDescription.new(name, period, (@priority_counter += 1))
            end
	end

        # Explicitely declares some frames
        #
        # This is usually not needed, as frames are implicitly declared with
        # #transform, #transform_output, #transform_input, 
        # #associate_frame_to_ports and #configurable_frames
        def frames(*frame_names)
            frame_names.each do |name|
                if name.respond_to?(:to_sym)
                    name = name.to_s
                elsif name.respond_to?(:to_str)
                    name = name.to_str
                else
                    raise ArgumentError, "frame names should be strings, got #{name.inspect}"
                end

                name = name.to_s
                if name !~ /^\w+$/
                    raise ArgumentError, "frame names can only contain alphanumeric characters and _, got #{name}"
                end

                if !has_frame?(name.to_str)
                    available_frames << name.to_str
                end
            end
            available_frames
        end

        # Declares that the provided frames should be configurable, i.e. that
        # properties allowing to set their global name exists
        def configurable_frames(*frame_names)
            if frame_names.empty?
                @configurable_frames
            else
                frames(*frame_names)
                frame_names.each do |name|
                    name = name.to_s
                    if !supercall(false, :configurable?, name)
                        # Name validation has already been done by #frames
                        @configurable_frames << name
                    end
                end
            end
        end

        # True if the global name for the local +frame_name+ needs to be configured on the task itself
        def configurable?(frame_name)
            !needs_transformer? || task.has_property?("#{frame_name}_frame") || @configurable_frames.include?(frame_name) ||
                supercall(false, :configurable?, frame_name)
        end

        def static?(frame_name)
            needs_transformer? && !configurable?(frame_name)
        end

        # Returns true if +frame_name+ is a known name for a frame on this
        # component
        def has_frame?(frame_name)
            frame_name = frame_name.to_s
            available_frames.include?(frame_name) ||
                supercall(false, :has_frame?, frame_name)
        end

        # Enumerates all known frames
        def each_frame(&block)
            if !block_given?
                return enum_for(:each_frame)
            end

            available_frames.each(&block)
            supercall(nil, :each_frame, &block)
        end
        
        # Enumerates all frames that can be configured at runtime
        def each_dynamicall_mapped_frame(&block)
            available_frames.each do |frame_name|
                if has_property?("#{frame_name}_frame")
                    yield(frame_name)
                end
            end
            supercall(nil, :each_dynamicall_mapped_frame, &block)
        end

        # Enumerates the (port, transform) pairs that describe the
        # transformations this component emits
        #
        # @yieldparam [Orocos::Spec::Port] port
        # @yieldparam [TransformationPort] transformation
        def each_transform_output(&block)
            transform_outputs.each(&block)
            supercall(nil, :each_transform_output, &block)
        end

        # Enumerates the (port, transform) pairs that describe the
        # transformations this component receives
        #
        # @yieldparam [Orocos::Spec::Port] port
        # @yieldparam [TransformationPort] transformation
        def each_transform_input(&block)
            transform_inputs.each(&block)
            supercall(nil, :each_transform_input, &block)
        end

        # Enumerates all ports that are associated with a transform
        #
        # @yieldparam [Orocos::Spec::Port] port
        # @yieldparam [TransformationPort] transformation
        def each_transform_port(&block)
            return enum_for(__method__) if !block_given?
            transform_associations.each(&block)
            supercall(nil, :each_transform_port, &block)
        end

        # Enumerates all transformations that the transformer should make
        # available, at runtime, to the component
        def each_needed_transformation(&block)
            if !block_given?
                return enum_for(:each_needed_transformation)
            end

            needed_transformations.each(&block)
            supercall(nil, :each_needed_transformation, &block)
        end

        # Enumerates all transformations declared within this component
        def each_transformation(&block)
            if !block_given?
                return enum_for(:each_transformation)
            end

            seen = Set.new
            needed_transformations.each do |trsf|
                key = [trsf.from, trsf.to]
                if !seen.include?(key)
                    seen << key
                    yield(trsf)
                end
            end
            transform_inputs.each_value do |trsf|
                key = [trsf.from, trsf.to]
                if !seen.include?(key)
                    seen << key
                    yield(trsf)
                end
            end
            transform_outputs.each_value do |trsf|
                key = [trsf.from, trsf.to]
                if !seen.include?(key)
                    seen << key
                    yield(trsf)
                end
            end

            supercall(nil, :each_transformation, &block)
        end

        # If +port+ has a transformation associated with #transform_output or
        # #transform_input, returns it. Otherwise, returns nil
        def find_transform_of_port(port)
            if port.respond_to?(:name)
                port_name = port.name
            else port_name = port
            end
            port = task.find_port(port_name)

            if !port
                raise ArgumentError, "#{task} has no port called #{port_name}"
            elsif result = transform_associations[port]
                result
            elsif (supertask = supercall(nil, :task)) && supertask.has_port?(port_name)
                supercall(nil, :find_transform_of_port, port)
            end
        end

        # Like #find_transform_of_port, but raises ArgumentError if there is no
        # associated transformation 
        def transform_of_port(port)
            if result = find_transform_of_port(port)
                result
            else
                raise ArgumentError, "port #{port} has no associated transformation"
            end
        end

        # Enumerates the (port_name, frame_name) pairs for all ports that have a
        # frame associated
        #
        # @yieldparam [Orocos::Spec::Port] port
        # @yieldparam [String] frame_name
        def each_annotated_port(&block)
            if !block_given?
                return enum_for(:each_annotated_port)
            end
            frame_associations.each(&block)
            supercall(nil, :each_annotated_port, &block)
        end

        # @deprecated use #associate_ports_to_frame instead
        def associate_frame_to_ports(frame_name, *port_names)
            Transformer.warn "#associate_frame_to_ports is deprecated, use #associate_ports_to_frame instead"
            associate_ports_to_frame(*port_names, frame_name)
        end

        # @!method associate_ports_to_frame(port1[, port2, ...], frame_name)
        #
        # Associates the provided ports (inputs and/or outputs) to the given
        # frame
        def associate_ports_to_frame(*ports_and_frame)
            if ports_and_frame.size < 2
                raise ArgumentError, "expected at least 2 arguments, got only #{ports_and_frame.size}"
            end
            *ports, frame = *ports_and_frame

            frames(frame)
            ports.each do |port_name|
                if !task.has_port?(port_name)
                    raise ArgumentError, "task #{task.name} has no port called #{port_name}"
                end
                port = task.find_port(port_name)
                # WARN: do not verify here that +port+ is NOT of type
                # RigidBodyState. The reason is that some components will
                # provide transformations between two temporal states of the
                # same frame, and for those it is actually useful to associate
                # them with said frame.
                #
                # I.e., for instance, odometry modules provide "incremental
                # updates", which are the transformations between the odometry
                # frame at t and the odometry frame at t+1
                frame_associations[port] = frame
            end
        end

        # @!method associate_ports_to_transform(port1[, port2, ...], source_frame => target_frame)
        #
        # Associate the given ports to a transform
        #
        # Unlike {#transform_input}, the data coming from the port is not
        # assumed to be fed to the transformer inside the component. This means
        # that the same transform might be provided to the underlying component
        # if needed
        def associate_ports_to_transform(*ports_and_transform)
            if ports_and_transform.size < 2
                raise ArgumentError, "expected at least 2 arguments, got only #{ports_and_transform.size}"
            end
            *ports, transform = *ports_and_transform
            if !transform.kind_of?(Hash)
                raise ArgumentError, "expected the last argument to be a hash representing the transform"
            elsif transform.size != 1
                raise ArgumentError, "expected the last argument to be a hash representing a single transform"
            end

            transform = transform.first
            frames(*transform)
            ports.each do |port_name|
                if !task.has_port?(port_name)
                    raise ArgumentError, "task #{task.name} has no port called #{port_name}"
                end
                port = task.find_port(port_name)
                transform_associations[port] = TransformationPort.new(*transform, port)
            end
        end

        # Returns the frame in which the data flowing through port +port+ is
        # represented.
        #
        # @arg [String,Orocos::Spec::Port] the port whose frame we are looking
        # for
        def find_frame_of_port(port)
            if port.respond_to?(:to_str)
                port = task.find_port(port)
            end
            if result = frame_associations[port]
                result
            else
                supercall(nil, :find_frame_of_port, port)
            end
        end

        # Like #find_frame_of_port, but raises ArgumentError if +port+ has no
        # associated frame
        def frame_of_port(port)
            if result = find_frame_of_port(port)
                return result
            else raise ArgumentError, "#{port} has no frame annotation"
            end
        end

        # Declares that the component will, at runtime, need the transformation
        # from +from+ to +to+ to perform its computation
        #
        # The frames are marked as configurable
	def transform(from, to)
            configurable_frames(from, to)
	    needed_transformations.push(NeededTransformation.new(from.to_s, to.to_s))
	end

        # @deprecated
        #
        # Use #transform instead (for consistency with #transform_input and
        # #transform_output
        def transformation(from, to)
            transform(from, to)
        end

        # Declares that the data flowing through +port_name+ provides a
        # transformation between the given frames.
        def transform_input(port_name, transform)
            if !task.has_input_port?(port_name)
                raise ArgumentError, "task #{task.name} has no input port called #{port_name}"
            end
            associate_ports_to_transform(port_name, transform)
            spec = transform_port(port_name, transform)
            transform_inputs[task.find_input_port(port_name)] = spec
            TransformationConfigurationProxy.new(self, spec)
        end

        # Declares that the data flowing through +port_name+ provides a
        # transformation between the given frames.
        def transform_output(port_name, transform)
            if !task.has_output_port?(port_name)
                raise ArgumentError, "task #{task.name} has no output port called #{port_name}"
            end
            associate_ports_to_transform(port_name, transform)
            spec = transform_port(port_name, transform)
            transform_outputs[task.find_output_port(port_name)] = spec
            TransformationConfigurationProxy.new(self, spec)
        end

        # Helper method for #transform_input and #transform_output
        def transform_port(port_name, transform) # :nodoc:
            if !transform.kind_of?(Hash)
                raise ArgumentError, "expected 'produces port_name, from => to', but got #{transform} instead of from => to"
            elsif transform.size > 1
                raise ArgumentError, "more than one transformation provided as production of port #{port_name}"
            end
            from, to = *transform.to_a.first
            frames(from, to)
            from, to = from.to_str, to.to_str

            if !task.has_port?(port_name)
                raise ArgumentError, "task #{task.name} has no port called #{port_name}"
            end

            p = task.find_port(port_name)
            if !Transformer.transform_port?(p)
                raise ArgumentError, "port #{port_name} (#{p.type.name}) of task #{task.name} does not have a type compatible with being a transformation input or output"
            end

            TransformationPort.new(from, to, p)
        end

        # Called to add the interface objects required by the transformer
        #
        # It can be called repeatedly, in which case only the new elements will
        # be added
        def update_spec
            return if !needs_transformer?

            Orocos::Spec.info("transformer: adding needs_configuration")
            task.needs_configuration

            # Don't add the general stuff if it has already been added
            if !task.has_property?("#{name}_max_latency")
                task.project.import_types_from "base"
                task.project.import_types_from "transformer"

                task.property("#{name}_max_latency", '/double', max_latency).
                    doc "Maximum time in seconds the transformer will wait until it starts dropping samples"
                Orocos::Spec.info("transformer: adding property #{name}_max_latency to #{task.name}")

                task.project.import_types_from('aggregator')

                ## Status ports and period property
                task.output_port("#{name}_stream_aligner_status", '/aggregator/StreamAlignerStatus').
		    doc "Status information on the stream aligner that is underlying the transformer."
                Orocos::Spec.info("transformer: adding port #{name}_status to #{task.name}")
                task.output_port("#{name}_status", '/transformer/TransformerStatus').
                    doc "Status information on the transformer internal state"
                Orocos::Spec.info("transformer: adding output port #{name}_status to #{task.name}")
		task.property("#{name}_status_period", '/double', 1.0).
		    doc "Minimum system time in seconds between two updates of the status ports"
		Orocos::Spec.info("Adding property #{name}_status_period to #{task.name}")
                
                # Create ports for transformations
                task.property('static_transformations', '/std/vector</base/samples/RigidBodyState>').
                    doc "list of static transformations"
                task.input_port('dynamic_transformations', '/base/samples/RigidBodyState').
                    multiplexes.
                    needs_reliable_connection
            end

            # Add period property for every data stream
            streams.each do |stream|
                property_name = "#{stream.name}_period"
                if !task.find_property(property_name)
                    task.property(property_name,   '/double', stream.period).
                        doc "Time in s between #{stream.name} readings"
                    Orocos::Spec.info("transformer: adding property #{property_name} to #{task.name}")
                end
            end	    

            # Add a configuration property for the configurable frame names
            configurable_frames.each do |name|
                if !task.find_property("#{name}_frame")
                    task.property("#{name}_frame", "/std/string", name).
                        doc("the global name that should be used for the internal #{name} frame")
                end
            end            
        end
        
        def get_transform_code
            #also do frame mapping in case the transformations are requested
            frame_selection = configurable_frames.sort.map do |frame_name|
                "    _#{name}.setFrameMapping(\"#{frame_name}\", _#{frame_name}_frame);"
            end.compact
            #add method to request needed transformations
            frame_selection.join("\n") + " \n
    std::vector<transformer::TransformationDescription > ret;
    const std::vector<transformer::Transformation *> &transformations(_transformer.getRegisteredTransformations());
    ret.reserve(transformations.size());
    
    for(std::vector<transformer::Transformation *>::const_iterator transform = transformations.begin();
        transform != transformations.end(); transform++)
    {
        transformer::TransformationDescription curTr;
        curTr.sourceFrame = (*transform)->getSourceFrame();
        curTr.targetFrame = (*transform)->getTargetFrame();
        
        ret.push_back(curTr);
    }
    
    return ret;"
        end

        # Lists the frames for which a configuration interface should be
        # provided
        def each_dynamically_mapped_frame
            if !block_given?
                return enum_for(:each_dynamically_mapped_frame)
            end

            each_frame do |frame_name|
                yield(frame_name) if configurable?(frame_name)
            end
        end

        # Lists the frames that have a hardcoded value inside the component
        def each_statically_mapped_frame
            if !block_given?
                return enum_for(:each_statically_mapped_frame)
            end

            each_frame do |frame_name|
                next if configurable?(frame_name)

                # Note: a non-configurable frame is not necessarily a statically
                # mapped ones ... Some frames are not used by the component at
                # all !
                #
                # Just yield if the frame is used as a transformation output
                each_transform_output do |port, transform|
                    if transform.from == frame_name || transform.to == frame_name
                        yield(frame_name) 
                        break
                    end
                end
            end
        end

        # True if the task implementation will need a transformer infrastructure
        # to deal with the declared transformations
        def needs_transformer?
            !needed_transformations.empty? || !streams.empty? || supercall(nil, :needs_transformer?)
        end
        
        
        # Called by the oroGen C++ code generator to add code objects to the
        # task implementation
        def early_register_for_generation(task)
            if needs_transformer?
                task.hidden_operation("getNeededTransformations").
                    base_body(get_transform_code).
                    returns('std::vector<transformer::TransformationDescription>')
            end
        end

        # Called by the oroGen C++ code generator to add code objects to the
        # task implementation
        def generation_hook(task)
            if needs_transformer?
                Generator.new.generate(task, self)
            end
        end

        # Called by Orocos::Spec::TaskContext#pretty_print to pretty-print the
        # transformer configuration
        def pretty_print(pp)
            pp.text "Frames: #{available_frames.to_a.sort.join(", ")}"

            pp.breakable
            pp.text "Needed Transformations:"
            transforms = each_transformation.map { |tr| [tr.from, tr.to] }.sort
            if !transforms.empty?
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(transforms) do |tr|
                        pp.text "%s => %s" % tr
                    end
                end
            end

            pp.breakable
            pp.text "Frame/Port Associations:"
            associations = each_annotated_port.map { |port, frame| [port.name, frame] }.sort
            if !associations.empty?
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(associations) do |portdef|
                        pp.text "data of %s is in frame %s" % portdef
                    end
                end
            end

            pp.breakable
            pp.text "Transform Inputs and Outputs:"
            ports = each_transform_port.map { |port, transform| [port.name, transform.from, transform.to] }.sort
            if !ports.empty?
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(ports) do |portdef|
                        pp.text "%s: %s => %s" % portdef
                    end
                end
            end
        end
    end
end


class Orocos::Spec::TaskContext
    def has_transformer?
        !!find_extension("transformer")
    end

    def transformer(&block)
        if !block_given?
            if self_ext = find_extension("transformer", false)
                return self_ext
            elsif inherited = find_extension("transformer", true)
                return TransformerPlugin::Extension.new("transformer", self)
            else return
            end
        end

        if !(config = find_extension("transformer", false))
            config = TransformerPlugin::Extension.new("transformer", self)
            if (tr = superclass.find_extension("transformer")) && tr.max_latency
                config.max_latency tr.max_latency
            end
            PortListenerPlugin.add_to(self)
        end

        config.instance_eval(&block)
        if config.needs_transformer? && !config.max_latency
            raise "not max_latency specified for transformer" 
        end

        config.update_spec
        register_extension(config)
        config
    end
end

