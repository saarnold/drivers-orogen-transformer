/* Generated from orogen/lib/orogen/templates/tasks/Task.cpp */

#include "Task.hpp"

using namespace transformer;

Task::Task(std::string const& name, TaskCore::TaskState initial_state)
    : TaskBase(name, initial_state)
{
    _configuration_state.keepLastWrittenValue(true);
}

Task::Task(std::string const& name, RTT::ExecutionEngine* engine, TaskCore::TaskState initial_state)
    : TaskBase(name, engine, initial_state)
{
    _configuration_state.keepLastWrittenValue(true);
}

Task::~Task()
{
}

bool Task::hasPortFrameAssociation(std::string const& task, std::string const& port) const
{
    for (unsigned int i = 0; i < mPortFrame.size(); ++i)
        if (mPortFrame[i].task == task && mPortFrame[i].port == port)
            return true;
    return false;
}

bool Task::hasPortFrameAssociation(std::string const& task, std::string const& port, std::string const& frame) const
{
    for (unsigned int i = 0; i < mPortFrame.size(); ++i)
        if (mPortFrame[i].task == task && mPortFrame[i].port == port && mPortFrame[i].frame == frame)
            return true;
    return false;
}

bool Task::hasPortTransformationAssociation(std::string const& task, std::string const& port) const
{
    for (unsigned int i = 0; i < mPortTransform.size(); ++i)
        if (mPortTransform[i].task == task && mPortTransform[i].port == port)
            return true;
    return false;
}

bool Task::hasPortTransformationAssociation(std::string const& task, std::string const& port, std::string const& from_frame, std::string const& to_frame) const
{
    for (unsigned int i = 0; i < mPortTransform.size(); ++i)
    {
        if (mPortTransform[i].task == task && mPortTransform[i].port == port &&
                mPortTransform[i].from_frame == from_frame &&
                mPortTransform[i].to_frame == to_frame)
            return true;
    }
    return false;
}

bool Task::addPortFrameAssociation(::std::string const & task, ::std::string const & port, ::std::string const & frame)
{
    if (hasPortTransformationAssociation(task, port))
        return false;
    if (hasPortFrameAssociation(task, port, frame))
        return true;
    mPortFrame.push_back(PortFrameAssociation(task, port, frame));
    pushState();
    return true;
}
bool Task::addPortTransformationAssociation(::std::string const & task, ::std::string const & port, ::std::string const & from_frame, ::std::string const & to_frame)
{
    if (hasPortFrameAssociation(task, port))
        return false;
    if (hasPortTransformationAssociation(task, port, from_frame, to_frame))
        return true;
    mPortTransform.push_back(PortTransformationAssociation(task, port, from_frame, to_frame));
    pushState();
    return true;
}
bool Task::removeAllPortFrameAssociations(::std::string const & task, ::std::string const & port)
{
    unsigned int j = 0;
    for (unsigned int i = 0; i < mPortFrame.size(); ++i)
    {
        if (mPortFrame[i].task != task || mPortFrame[i].port != port)
        {
            if (i != j)
                mPortFrame[j] = mPortFrame[i];
            ++j;
        }
    }
    if (j == mPortFrame.size())
        return false;

    mPortFrame.resize(j);
    pushState();
    return true;
}
bool Task::removeAllPortTransformationAssociations(::std::string const & task, ::std::string const & port)
{
    unsigned int j = 0;
    for (unsigned int i = 0; i < mPortTransform.size(); ++i)
    {
        if (mPortTransform[i].task != task || mPortTransform[i].port != port)
        {
            if (i != j)
                mPortTransform[j] = mPortTransform[i];
            ++j;
        }
    }
    if (j == mPortTransform.size())
        return false;

    mPortTransform.resize(j);
    pushState();
    return true;
}

bool Task::removePortFrameAssociation(::std::string const & task, ::std::string const & port, ::std::string const & frame)
{
    std::vector<PortFrameAssociation>::iterator it =
        find(mPortFrame.begin(), mPortFrame.end(), PortFrameAssociation(task, port, frame));
    if (it == mPortFrame.end())
        return false;
    mPortFrame.erase(it);
    pushState();
    return true;
}
bool Task::removePortTransformationAssociation(::std::string const & task, ::std::string const & port, ::std::string const & from_frame, ::std::string const & to_frame)
{
    std::vector<PortTransformationAssociation>::iterator it =
        find(mPortTransform.begin(), mPortTransform.end(), PortTransformationAssociation(task, port, from_frame, to_frame));
    if (it == mPortTransform.end())
        return false;
    mPortTransform.erase(it);
    pushState();
    return true;
}

void Task::pushState()
{
    ConfigurationState state;
    state.port_frame_associations = mPortFrame;
    state.port_transformation_associations = mPortTransform;
    state.static_transformations = mStaticTransforms;
    _configuration_state.write(state);
}

/// The following lines are template definitions for the various state machine
// hooks defined by Orocos::RTT. See Task.hpp for more detailed
// documentation about them.

// bool Task::configureHook()
// {
//     if (! TaskBase::configureHook())
//         return false;
//     return true;
// }
// bool Task::startHook()
// {
//     if (! TaskBase::startHook())
//         return false;
//     return true;
// }
// void Task::updateHook()
// {
//     TaskBase::updateHook();
// }
// void Task::errorHook()
// {
//     TaskBase::errorHook();
// }
// void Task::stopHook()
// {
//     TaskBase::stopHook();
// }
void Task::cleanupHook()
{
    mPortFrame.clear();
    mPortTransform.clear();
    mStaticTransforms.clear();
    TaskBase::cleanupHook();
}

