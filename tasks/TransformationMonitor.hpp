/* Generated from orogen/lib/orogen/templates/tasks/Task.hpp */

#ifndef TRANSFORMER_TRANSFORMATIONMONITOR_TASK_HPP
#define TRANSFORMER_TRANSFORMATIONMONITOR_TASK_HPP

#include "transformer/TransformationMonitorBase.hpp"
#include "transformer/Transformer.hpp"

namespace transformer {
class TransformationMonitor : public TransformationMonitorBase
{
    friend class TransformationMonitorBase;
protected:
    //Usually done by orogen
    Transformer _transformer;
    transformer::TransformerStatus transformerStatus;
    base::Time _nextStatusTime;
    //End of orogen part

    typedef std::map<std::string, RTT::OutputPort<base::samples::RigidBodyState>* > PortMap;
    typedef std::map<std::string, RTT::OutputPort<base::samples::RigidBodyState>* >::iterator PortMapIterator;
    typedef std::map<std::string, Transformation*> TransformationMap;
    typedef std::map<std::string, Transformation*>::iterator TransformationMapIterator;
    typedef std::map<std::string, TransformationStatus> TransformerStatusMap;
    typedef std::map<std::string, TransformationStatus>::iterator TransformerStatusMapIterator;

    //FIXME: Is this mutex really necessary?
    pthread_mutex_t callback_lock;

    PortMap port_map_;
    TransformationMap transformations_map_;
    TransformerStatusMap transformer_status_map_;

    std::vector<std::string> get_all_tranforms_ids();
    std::string make_transform_id(const TransformDefinition& transform);
    bool is_registered(const TransformDefinition& transform);
    bool is_registered(const std::string& transform);
    bool do_register_transform(const TransformDefinition& transform);
    bool do_deregister_transform(const TransformDefinition& transform);
    bool do_deregister_transform(const std::string& transform_id);
    void deregister_all_transforms();
    void updateTransformerStatus();
    void callback(const base::Time& time, const Transformation& transformation);

     virtual std::string register_transform(TransformDefinition const & the_argument);
     virtual void deregister_transform(TransformDefinition const & the_argument);
public:
    TransformationMonitor(std::string const& name = "transformer::TransformWriter");

    TransformationMonitor(std::string const& name, RTT::ExecutionEngine* engine);

    ~TransformationMonitor();

    bool configureHook();
    bool startHook();
    void updateHook();
    void errorHook();
    void stopHook();
    void cleanupHook();
};
}

#endif

