/* Generated from orogen/lib/orogen/templates/tasks/Task.hpp */

#ifndef TRANSFORMER_TRANSFORMATIONPROXY_TASK_HPP
#define TRANSFORMER_TRANSFORMATIONPROXY_TASK_HPP

#include "transformer/TransformationProxyBase.hpp"

namespace transformer {

    class TransformationProxy : public TransformationProxyBase
    {
	friend class TransformationProxyBase;
    protected:



    public:
        TransformationProxy(std::string const& name = "transformer::TransformationProxy", TaskCore::TaskState initial_state = Stopped);

        TransformationProxy(std::string const& name, RTT::ExecutionEngine* engine, TaskCore::TaskState initial_state = Stopped);


	~TransformationProxy();

        bool configureHook();
        bool startHook();

        void updateHook();

        void errorHook();


        void stopHook();

        void cleanupHook();
    };
}

#endif

