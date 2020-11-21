
const EpollCtlError = error {
    FileDescriptorAlreadyPresentInSet,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    Unexpected,
};

pub const EventerAddError = EpollCtlError;
pub const EventerModifyError = EpollCtlError;
