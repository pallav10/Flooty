const SUBSCRIPTION_KEYCHAIN_SERVICE = "org.flooty.subscription"
const SUBSCRIPTION_SECURITY = "/System/Library/Frameworks/Security.framework/Security"
const SUBSCRIPTION_CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
const SUBSCRIPTION_ITEM_NOT_FOUND = Int32(-25300)

function findSubscriptionSecret(provider::String)
    Sys.isapple() || throw(ArgumentError("Subscription credential storage requires macOS Keychain."))
    length = Ref{UInt32}(0)
    data = Ref{Ptr{UInt8}}(C_NULL)
    item = Ref{Ptr{Cvoid}}(C_NULL)
    status = ccall((:SecKeychainFindGenericPassword, SUBSCRIPTION_SECURITY), Int32,
                   (Ptr{Cvoid}, UInt32, Ptr{UInt8}, UInt32, Ptr{UInt8},
                    Ref{UInt32}, Ref{Ptr{UInt8}}, Ref{Ptr{Cvoid}}),
                   C_NULL, ncodeunits(SUBSCRIPTION_KEYCHAIN_SERVICE), SUBSCRIPTION_KEYCHAIN_SERVICE,
                   ncodeunits(provider), provider, length, data, item)
    return (; status, length = length[], data = data[], item = item[])
end

function freeSubscriptionSecret(found)
    found.data == C_NULL || ccall((:SecKeychainItemFreeContent, SUBSCRIPTION_SECURITY), Int32,
                                  (Ptr{Cvoid}, Ptr{Cvoid}), C_NULL, found.data)
    found.item == C_NULL || ccall((:CFRelease, SUBSCRIPTION_CORE_FOUNDATION), Cvoid,
                                  (Ptr{Cvoid},), found.item)
    return nothing
end

function readSubscriptionSecret(provider::String)::Union{Nothing,String}
    found = findSubscriptionSecret(provider)
    try
        found.status == SUBSCRIPTION_ITEM_NOT_FOUND && return nothing
        found.status == 0 || error("Keychain could not read subscription credentials (OSStatus $(found.status)).")
        return unsafe_string(found.data, found.length)
    finally
        freeSubscriptionSecret(found)
    end
end

function writeSubscriptionSecret(provider::String, secret::String)
    found = findSubscriptionSecret(provider)
    try
        status = if found.status == SUBSCRIPTION_ITEM_NOT_FOUND
            ccall((:SecKeychainAddGenericPassword, SUBSCRIPTION_SECURITY), Int32,
                  (Ptr{Cvoid}, UInt32, Ptr{UInt8}, UInt32, Ptr{UInt8}, UInt32, Ptr{UInt8}, Ptr{Cvoid}),
                  C_NULL, ncodeunits(SUBSCRIPTION_KEYCHAIN_SERVICE), SUBSCRIPTION_KEYCHAIN_SERVICE,
                  ncodeunits(provider), provider, ncodeunits(secret), secret, C_NULL)
        elseif found.status == 0
            ccall((:SecKeychainItemModifyAttributesAndData, SUBSCRIPTION_SECURITY), Int32,
                  (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt8}),
                  found.item, C_NULL, ncodeunits(secret), secret)
        else
            found.status
        end
        status == 0 || error("Keychain could not save subscription credentials (OSStatus $status).")
    finally
        freeSubscriptionSecret(found)
    end
    return nothing
end

const SUBSCRIPTION_STORE_READ = Ref{Function}(readSubscriptionSecret)
const SUBSCRIPTION_STORE_WRITE = Ref{Function}(writeSubscriptionSecret)
