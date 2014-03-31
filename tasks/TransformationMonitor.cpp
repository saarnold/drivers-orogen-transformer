/* Generated from orogen/lib/orogen/templates/tasks/Task.cpp */

#include "TransformationMonitor.hpp"

using namespace transformer;

TransformationMonitor::TransformationMonitor(std::string const& name)
    : TransformationMonitorBase(name)
{
    if (pthread_mutex_init(&callback_lock, NULL) != 0){
        throw("\n mutex init failed\n");
    }
}

TransformationMonitor::TransformationMonitor(std::string const& name, RTT::ExecutionEngine* engine)
    : TransformationMonitorBase(name, engine)
{
    if (pthread_mutex_init(&callback_lock, NULL) != 0){
        throw("\n mutex init failed\n");
    }
}

TransformationMonitor::~TransformationMonitor()
{
    deregister_all_transforms();
    pthread_mutex_destroy(&callback_lock);
}

std::vector<std::string> TransformationMonitor::get_all_tranforms_ids()
{
    std::vector<std::string> ret(port_map_.size());
    for(PortMapIterator it = port_map_.begin();
        it != port_map_.end(); ++it) {
        ret.push_back(it->first);
    }
    return ret;
}

std::string TransformationMonitor::make_transform_id(const TransformDefinition& transform)
{
    return transform.source_frame + "2" + transform.target_frame;
}

void TransformationMonitor::callback(const base::Time& time, const Transformation& transformation)
{
    int rc = pthread_mutex_lock(&callback_lock);
    TransformDefinition tr;
    tr.source_frame = transformation.getSourceFrame();
    tr.target_frame = transformation.getTargetFrame();

    std::string tr_id = make_transform_id(tr);
    assert(is_registered(tr_id));

    base::samples::RigidBodyState rbs;
    transformation.get(time, rbs);
    port_map_[tr_id]->write(rbs);
    rc = pthread_mutex_unlock(&callback_lock);
}

bool TransformationMonitor::is_registered(const std::string& transform)
{
    PortMapIterator it;
    it = port_map_.find(transform);

    if(it == port_map_.end())
        return false;
    else
        return true;
}

bool TransformationMonitor::is_registered(const TransformDefinition& transform)
{
    return is_registered(make_transform_id(transform));
}

bool TransformationMonitor::do_register_transform(const TransformDefinition& transform)
{
    int rc = pthread_mutex_lock(&callback_lock);
    if(is_registered(transform)){
        LOG_WARN("Transform %s --> %s already was registered",
                 transform.source_frame.c_str(), transform.target_frame.c_str());
        rc = pthread_mutex_unlock(&callback_lock);
        return false;
    }

    //Create output port
    std::string transform_id = make_transform_id(transform);
    LOG_INFO("Adding port %s to component", transform_id.c_str());
    RTT::OutputPort<base::samples::RigidBodyState>* output_port =
            new RTT::OutputPort<base::samples::RigidBodyState>(transform_id);
    ports()->addPort(transform_id, *output_port);

    //Store
    port_map_[transform_id] = output_port;

    //Register at transformer
    transformations_map_[transform_id] = &(_transformer.registerTransformation(
                                               transform.source_frame, transform.target_frame));

    //Register callback
    _transformer.registerTransformCallback(*(transformations_map_[transform_id]),
                                           boost::bind(&TransformationMonitor::callback,
                                                       this, _1, _2));
    rc = pthread_mutex_unlock(&callback_lock);
}

bool TransformationMonitor::do_deregister_transform(const std::string& transform_id)
{
    //TODO: When unregistering a transform, the vcomponent crashed in the callback.
    //It seems, htat the callback is still called event though
    // _transformer.unregisterTransformation(transformations_map_[transform_id]);
    //Is called. Maybe in transformer deregistration is buggy.
    return false;

    int rc = pthread_mutex_lock(&callback_lock);
    if(!is_registered(transform_id)){
        LOG_WARN("Transform %s was not registered",
                 transform_id.c_str());
        rc = pthread_mutex_unlock(&callback_lock);
        return false;
    }
    _transformer.unregisterTransformation(transformations_map_[transform_id]);
    PortMapIterator p_it;
    p_it = port_map_.find(transform_id);
    ports()->removePort(transform_id);
    //delete p_it->second;
    port_map_.erase(p_it);

    TransformationMapIterator t_it;
    t_it = transformations_map_.find(transform_id);
    transformations_map_.erase(t_it);

    TransformerStatusMapIterator s_it;
    s_it = transformer_status_map_.find(transform_id);
    transformer_status_map_.erase(s_it);

    rc = pthread_mutex_unlock(&callback_lock);
    return true;
}

bool TransformationMonitor::do_deregister_transform(const TransformDefinition& transform)
{
    return do_deregister_transform(make_transform_id(transform));
}

void TransformationMonitor::deregister_all_transforms(){
    std::vector<std::string> all_transform_ids = get_all_tranforms_ids();
    for(size_t i=0; i<all_transform_ids.size(); i++){
        do_deregister_transform(all_transform_ids[i]);
    }

    assert(port_map_.empty());
    assert(transformations_map_.empty());
}

//The operations
std::string TransformationMonitor::register_transform(TransformDefinition const & the_argument)
{
    bool st = do_register_transform(the_argument);
    return make_transform_id(the_argument);
}

void TransformationMonitor::deregister_transform(TransformDefinition const & the_argument)
{
    do_deregister_transform(the_argument);
}


/// The following lines are template definitions for the various state machine
// hooks defined by Orocos::RTT. See TransformationMonitor.hpp for more detailed
// documentation about them.

bool TransformationMonitor::configureHook()
{
    if (! TransformationMonitorBase::configureHook())
        return false;

    //Usually done by orogen
    _transformer.clear();
    _transformer.setTimeout( base::Time::fromSeconds( _transformer_max_latency.value()) );

    transformerStatus.transformations.clear();

    std::vector<base::samples::RigidBodyState> const& staticTransforms =
            _static_transformations.set();
    for (size_t i = 0; i < staticTransforms.size(); ++i)
        _transformer.pushStaticTransformation(staticTransforms[i]);

    transformerStatus.transformations.resize(1);
    //end of orogen part

    std::vector<TransformDefinition> transforms = _transforms.get();
    for(size_t i=0; i<transforms.size(); i++){
        do_register_transform(transforms[i]);
    }
    return true;
}
bool TransformationMonitor::startHook()
{
    if (! TransformationMonitorBase::startHook())
        return false;

    return true;
}

void TransformationMonitor::updateTransformerStatus()
{
    transformerStatus.transformations.resize(transformations_map_.size());
    int i=0;
    for(TransformationMapIterator it = transformations_map_.begin();
        it != transformations_map_.end(); ++it){
        std::string t_id = it->first;
        it->second->updateStatus(transformer_status_map_[t_id]);
        transformerStatus.transformations[i] = transformer_status_map_[t_id];
    }
    transformerStatus.time = base::Time::now();
    _transformer_status.write(transformerStatus);
}


void TransformationMonitor::updateHook()
{
    TransformationMonitorBase::updateHook();

    //usually done by orogen
    base::samples::RigidBodyState dynamicTransform;
    while(_dynamic_transformations.read(dynamicTransform, false) == RTT::NewData) {
        _transformer.pushDynamicTransformation(dynamicTransform);
    }

    const base::Time statusPeriod( base::Time::fromSeconds( _transformer_status_period.value() ) );
    do
    {
        const base::Time curTime(base::Time::now());
        if( curTime > _nextStatusTime )
        {
            _nextStatusTime = curTime + statusPeriod;
            _transformer_stream_aligner_status.write(_transformer.getStatus());
            updateTransformerStatus();
        }
    }
    while(_transformer.step());
    //end of orogen part
}
void TransformationMonitor::errorHook()
{
    TransformationMonitorBase::errorHook();
}
void TransformationMonitor::stopHook()
{
    TransformationMonitorBase::stopHook();
}
void TransformationMonitor::cleanupHook()
{
    TransformationMonitorBase::cleanupHook();
}
