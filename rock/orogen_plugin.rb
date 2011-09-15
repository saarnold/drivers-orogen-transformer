require 'aggregator_plugin'

module TransformerPlugin
    class Generator
        def generate_frame_mapping(task, config)
            transform_configuration = config.available_frames.map do |frame_name|
                "    _#{config.name}.setFrameMapping(\"#{frame_name}\", _#{frame_name});"
            end

            task.in_base_hook("start", transform_configuration.join("\n"))
        end

	def generate(task, config)
            port_listener_ext = task.extension("port_listener")
	    
	    task.add_base_header_code("#include <transformer/Transformer.hpp>", true)
	    #a_transformer to be shure that the transformer is declared BEFORE the Transformations
	    task.add_base_member("transformer", "_#{config.name}", "transformer::Transformer")
	    task.add_base_member("lastStatusTime", "_lastStatusTime", "base::Time")
	    
	    task.in_base_hook("configure", "
    #{config.name}.clear();
    #{config.name}.setTimeout( base::Time::fromSeconds( _transformer_max_latency.value()) );
	    ")	    
	    
	    config.each_needed_transformation.each do |t|
		task.add_base_member("transformer", member_name(t), "transformer::Transformation &").
		    initializer("#{member_name(t)}(_#{config.name}.registerTransformation(\"#{t.from}\", \"#{t.to}\"))")
	    end

            generate_frame_mapping(task, config)

            task.in_base_hook("start",
"    std::vector<base::samples::RigidBodyState> const& staticTransforms =
        _static_transformations.set();
     for (size_t i = 0; i < staticTransforms.size(); ++i)
        _#{config.name}.pushStaticTransformation(staticTransforms[i]);
")

	    config.streams.each do |stream|
		# Pull the data in the update hook
		port_listener_ext.add_port_listener(stream.name) do |sample_name|
                    "	_#{config.name}.pushData(#{idx_name(stream)}, #{sample_name}.time, #{sample_name});"
		end

		stream_data_type = type_cxxname(task, stream)
		
		#add variable for index
		task.add_base_member("transformer", idx_name(stream), "int")
		
		#add callbacks
		task.add_user_method("void", callback_name(stream), "const base::Time &ts, const #{stream_data_type} &#{stream.name}_sample").
		body("    throw std::runtime_error(\"Transformer callback for #{stream.name} not implemented\");")

		#register streams at transformer
		task.in_base_hook("configure", "
    {
    const double #{stream.name}Period = _#{stream.name}_period.value();
    #{idx_name(stream)} = _#{config.name}.registerDataStream< #{stream_data_type}>(
		    base::Time::fromSeconds(#{stream.name}Period), boost::bind( &#{task.class_name()}Base::#{callback_name(stream)}, this, _1, _2));
    }")

		#unregister in cleanup
		task.in_base_hook("cleanup", "     _#{config.name}.unregisterDataStream(#{idx_name(stream)});")
	    end

	    task.in_base_hook("update", "
    base::samples::RigidBodyState dynamicTransform;
    while(_dynamic_transformations.read(dynamicTransform, false) == RTT::NewData) {
	_#{config.name}.pushDynamicTransformation(dynamicTransform);
    }

    while(_#{config.name}.step()) 
    {
	;
    }")

	    task.in_base_hook('update', "
    {
	const base::Time curTime(base::Time::now());
	if(curTime - _lastStatusTime > base::Time::fromSeconds(1))
	{
	    _lastStatusTime = curTime;
	    _#{config.name}_status.write(_#{config.name}.getStatus());
	}
    }")

	    #unregister in cleanup
	    task.in_base_hook("stop", "
    _#{config.name}.clear();")
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

    # This class is used to add some information to the task's oroGen
    # specification
    #
    # It gets added when #transformer is called on the task context. It can be
    # retrieved with:
    #
    #   transformer = task_model.transformer
    #
    # Or, more generically
    #
    #   transformer = task_model.extension("transformer")
    #
    class Extension
        # Describes an input stream on the transformer. It behaves like a stream
        # on a stream aligner
	class StreamDescription
	    def initialize(name, period)
		@name   = name
		@period = period
	    end

	    attr_reader :name
	    attr_reader :period
	end
	
        # Describes a transformation
	class TransformationDescription
	    attr_reader :from
	    attr_reader :to
	    
	    def initialize(from, to)
		@from = from
		@to = to
	    end
	end

        # Describes a transformation
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
	
	dsl_attribute :name do |new_name|
            new_name = new_name.to_str
            if new_name !~ /^\w+$/
                raise ArgumentError, "transformer names can only contain alphanumeric characters and _"
            end
            @default_transformer = false
            new_name
        end

        attr_predicate :default?, true
        attr_predicate :producer?, true
        attr_predicate :consumer?, true

        attr_reader :task

	dsl_attribute :max_latency
	attr_reader :streams
        attr_reader :available_frames
        attr_reader :frame_associations
	attr_reader :needed_transformations
        attr_reader :transform_inputs
        attr_reader :transform_outputs

	def initialize(task)
            @task = task

	    @streams = Array.new()
            @name = "transformer"
            @default = true
            @available_frames = Set.new
            @frame_associations = Hash.new

	    @needed_transformations = Array.new
            @transform_outputs = Hash.new
            @transform_inputs  = Hash.new
	end
	
	def align_port(name, period)
	    streams << StreamDescription.new(name, period)
	end

        def has_frame?(frame_name)
            frame_name = frame_name.to_s
            available_frames.include?(frame_name)
        end

        def each_frame(&block)
            available_frames.each(&block)
        end

        def each_transform_output(&block)
            transform_outputs.each(&block)
        end

        def each_transform_input(&block)
            transform_inputs.each(&block)
        end

        def each_transform_port(&block)
            if !block
                return enum_for(:each_transform_port)
            end
            transform_inputs.each(&block)
            transform_outputs.each(&block)
        end

        def each_needed_transformation(&block)
            needed_transformations.each(&block)
        end

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
        end

        def find_transform_of_port(port)
            if port.respond_to?(:to_str)
                port = task.find_port(port)
            end

            transform_inputs[port] || transform_outputs[port]
        end

        def transform_of_port(port)
            if result = find_transform_of_port(port)
                result
            else
                raise ArgumentError, "port #{port} has no associated transformation"
            end
        end

        def each_annotated_port(&block)
            frame_associations.each(&block)
        end

        def associate_frame_to_port(frame_name, port_names)
            port_names.each do |pname|
                if !task.has_port?(pname)
                    raise ArgumentError, "task #{task.name} has no port called #{pname}"
                elsif !has_frame?(frame_name)
                    raise ArgumentError, "no frame #{frame_name} is declared"
                end
                port = task.find_port(pname)
                # WARN: do not verify here that +port+ is NOT of type
                # RigidBodyState. The reason is that some components will
                # provide transformations between two temporal states of the
                # same frame, and for those it is actually useful to associate
                # them with said frame.
                #
                # I.e., for instance, odometry modules provide "incremental
                # updates", which are the transformations between the odometry
                # frame at t and the odometry frame at t+1
                frame_associations[port] = frame_name
            end
        end

        def find_frame_of_port(port)
            if port.respond_to?(:to_str)
                port = task.find_port(port)
            end
            @frame_associations[port]
        end

        def frame_of_port(port)
            if result = find_frame_of_port(port)
                return result
            else raise ArgumentError, "#{port} has no frame annotation"
            end
        end

        def frames(*frame_names)
            if frame_names.last.kind_of?(Hash)
                port_frames = frame_names.pop
                frame_names = frame_names.to_set | port_frames.keys
            end

            frame_names.each do |name|
                name = name.to_s
                if name !~ /^\w+$/
                    raise ArgumentError, "frame names can only contain alphanumeric characters and _, got #{name}"
                end
                available_frames << name.to_str
            end

            if port_frames
                port_frames.each do |frame_name, port_names|
                    if !port_names.respond_to?(:to_ary)
                        port_names = [port_names]
                    end

                    associate_frame_to_port(frame_name, port_names)
                end
            end
        end

	def transformation(from, to)
            frames(from, to)
	    needed_transformations.push(TransformationDescription.new(from.to_s, to.to_s))
	end

        def transform_input(port_name, transform)
            if !task.has_input_port?(port_name)
                raise ArgumentError, "task #{task.name} has no input port called #{pname}"
            end
            spec = transform_port(port_name, transform)
            transform_inputs[task.find_input_port(port_name)] = spec
        end

        def transform_output(port_name, transform)
            if !task.has_output_port?(port_name)
                raise ArgumentError, "task #{task.name} has no output port called #{pname}"
            end
            spec = transform_port(port_name, transform)
            transform_outputs[task.find_output_port(port_name)] = spec
        end

        def transform_port(port_name, transform)
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

        def needs_transformer?
            !needed_transformations.empty?
        end

        def update_spec
            task.project.import_types_from "base"

            each_frame do |frame_name|
                if !task.has_property?("#{frame_name}_frame")
                    task.property("#{frame_name}_frame", "/std/string", frame_name).
                        doc("the global name that should be used for the internal #{frame_name} frame")
                end
            end

            if needs_transformer?
                update_transformer_spec
            end
        end

        def update_transformer_spec
            # Don't add the general stuff if it has already been added
            if !task.has_property?("transformer_max_latency")
                task.project.import_types_from "base"
                task.project.using_library('transformer', :typekit => false)

                task.property("transformer_max_latency", 'double', max_latency).
                    doc "Maximum time in seconds the transformer will wait until it starts dropping samples"
                Orocos::Generation.info("transformer: adding property transformer_max_latency to #{task.name}")

                task.project.import_types_from('aggregator')

                #add output port for status information
                task.output_port("#{self.name}_status", '/aggregator/StreamAlignerStatus')
                Orocos::Generation.info("transformer: adding port #{name}_status to #{task.name}")
                
                #create ports for transformations
                task.property('static_transformations', 'std::vector</base/samples/RigidBodyState>').
                    doc "list of static transformations"
                task.input_port('dynamic_transformations', '/base/samples/RigidBodyState').
                    needs_reliable_connection
            end
                
            #add period property for every data stream
            streams.each do |stream|
                property_name = "#{stream.name}_period"
                if !task.find_property(property_name)
                    task.property(property_name,   'double', stream.period).
                        doc "Time in s between #{stream.name} readings"
                    Orocos::Generation.info("transformer: adding property #{property_name} to #{task.name}")
                end
            end	    
        end

        def register_for_generation(task)
            if !consumer? && producer?
                Generator.new.generate_frame_mapping(task, self)
            elsif consumer?
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
    def transformer(&block)
        if !block_given?
            return find_extension("transformer")
        end

        if !(config = find_extension("transformer"))
            config = TransformerPlugin::Extension.new(self)
            PortListenerPlugin.add_to(self)
        end

        config.instance_eval(&block)
        if config.needs_transformer? && !config.max_latency
            raise "not max_latency specified for transformer" 
        end

        config.update_spec
        register_extension("transformer", config)
    end
end
