import Foundation
import CoreLocation

public final class LocationManager: NSObject, CLLocationManagerDelegate {
    public let manager = CLLocationManager()
    var pendingCompletion: ((CLAuthorizationStatus) -> Void, CLAuthorizationStatus)?
    
    public override init() {
        super.init()
        self.manager.delegate = self
    }

    private var authorizationStatus: CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return self.manager.authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }
    
    func requestWhenInUseAuthorization(completion: @escaping (CLAuthorizationStatus) -> Void) {
        let status = self.authorizationStatus
        if status == .notDetermined {
            self.manager.requestWhenInUseAuthorization()
            self.pendingCompletion = (completion, .authorizedWhenInUse)
        } else {
            completion(status)
        }
    }
    
    func requestAlwaysAuthorization(completion: @escaping (CLAuthorizationStatus) -> Void) {
        let status = self.authorizationStatus
        if status == .notDetermined {
            self.manager.requestWhenInUseAuthorization()
            self.pendingCompletion = (completion, .authorizedAlways)
        } else {
            completion(status)
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if let (pendingCompletion, _) = self.pendingCompletion {
            pendingCompletion(status)
            self.pendingCompletion = nil
        }
    }
}
