module Transformer
    module DeviceExtension
        ## 
        # Declares the frame in which this device produces data
        dsl_attribute :frame
    end

    module TaskContextExtension
        attribute(:frame_selection) { Hash.new }
        def select_frame(frame_name, selected_frame)
            if current = frame_selection[frame_name]
                if current != selected_frame
                    raise FrameMismatch, "cannot select both #{current} and #{selected_frame} for the frame #{frame_name} of #{self}"
                end
            end
        end
    end

    class FramePropagation < Orocos::RobyPlugin::DataFlowComputation
        class FrameAnnotation
            attr_reader :task
            attr_reader :frame_name
            attr_reader :selected_frame

            def initialize(task, frame_name, selected_frame)
                @task, @frame_name, @selected_frame = task, frame_name, selected_frame
            end

            def empty?; !@selected_frame end
            def merge(ann)
                if ann.name != name
                    raise FrameMismatch, "invalid network: frame #{frame_name} in #{task} would need to select both #{ann.selected_frame} and #{selected_frame}"
                end
            end
        end

        def required_information(tasks)
            result = Hash.new
            tasks.each do |t|
                next if !(tr = task.transformer)

                task_info = [nil]
                needed_frames = tr.available_frames.dup
                tr.each_associated_port do |port, frame|
                    needed_frames.delete(frame)
                    task_info << port
                end
                result[t] = task_info
            end
        end

        def triggering_inputs(task)
            return if !(tr = task.transformer)

            result = []
            tr.each_associated_port do |port, frame|
                if port.kind_of?(Orocos::Spec::InputPort)
                    result << port
                end
            end
            result
        end

        def initial_information(task)
            return if !(tr = task.transformer)

            # Add frame information from the devices if there is some
            if task.kind_of?(Orocos::RobyPlugin::Device)
                task.each_device do |srv, dev|
                    next if !(selected_frame = dev.frame)
                    srv.each_output_port(true) do |out_port|
                        task.select_frame(frame_name, selected_frame)
                    end
                end
            end

            # Now add information for all ports for which we know the frame
            # already
            tr.each_associated_port do |port, frame_name|
                if selected_frame = task.selected_frames[frame_name]
                    add_port_info(task, out_port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                    done_port_info(task, out_port.name)
                end
            end
        end

        def propagate_task(task)
            return if !(tr = task.transformer)

            tr.each_associated_port do |port, frame|
                if port.kind_of?(Orocos::Spec::InputPort) && !task.selected_frames[frame]
                    if has_information_for_port?(task, port.name)
                        task.selected_frames[frame] = port_info(task, port.name).selected_frame
                    end
                end
            end

            # We return true as soon as all associated port are assigned. The
            # algorithm won't be able to assign the internal frames anyway
            has_all = true
            tr.each_associated_port do |port, frame|
                if selected = task.selected_frame[frame]
                    if has_information_for_port?(task, port.name)
                        # Just call #select_frame to validate that the two
                        # frames are identical
                        task.select_frame(frame_name, port_info(task, port.name).selected_frame)
                    end
                else
                    has_all = false
                end
            end
            return has_all
        end
    end

    Orocos::RobyPlugin::Engine.instanciation_postprocessing do |engine, tasks|
    end
end

Orocos::RobyPlugin::TaskContext.include Transformer::TaskContextExtension
Orocos::RobyPlugin::DeviceInstance.include Transformer::DeviceExtension
