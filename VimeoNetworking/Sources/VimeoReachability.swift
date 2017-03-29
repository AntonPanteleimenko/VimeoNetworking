//
//  VimeoReachability.swift
//  Vimeo
//
//  Created by King, Gavin on 9/22/16.
//  Copyright © 2016 Vimeo. All rights reserved.
//

import UIKit
import AFNetworking

open class VimeoReachability
{
    private static var LastKnownReachabilityStatus = AFNetworkReachabilityStatus.unknown
    
    internal static func beginPostingReachabilityChangeNotifications()
    {
        AFNetworkReachabilityManager.shared().setReachabilityStatusChange { (status) in

            if LastKnownReachabilityStatus != status
            {
                LastKnownReachabilityStatus = status
                NetworkingNotification.ReachabilityDidChange.post(object: nil)
            }
        }
        
        AFNetworkReachabilityManager.shared().startMonitoring()
    }
    
    open static func reachable() -> Bool
    {
        return AFNetworkReachabilityManager.shared().isReachable
    }
    
    open static func reachableViaCellular() -> Bool
    {
        return AFNetworkReachabilityManager.shared().isReachableViaWWAN
    }
    
    open static func reachableViaWiFi() -> Bool
    {
        return AFNetworkReachabilityManager.shared().isReachableViaWiFi
    }
}
