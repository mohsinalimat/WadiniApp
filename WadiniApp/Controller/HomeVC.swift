//
//  ViewController.swift
//  WadiniApp
//
//  Created by Sherif Kamal on 10/14/18.
//  Copyright © 2018 Sherif Kamal. All rights reserved.
//

import UIKit
import MapKit
import RevealingSplashView
import Firebase

enum AnnotationType {
    case pickup
    case destination
    case driver
}

enum ButtonAction {
    case confirmPickup
    case confirmDropoff
    case requestRide
    case getDirectionsToPassenger
    case getDirectionsToDestination
    case startTrip
    case endTrip
}

class HomeVC: UIViewController, Alertable {
    
    //MARK: - Outlets
    @IBOutlet weak var mapView: MKMapView!
    @IBOutlet weak var pickupLocationLbl: UILabel!
    @IBOutlet weak var pickupLocationTitleLbl: UILabel!
    
    @IBOutlet weak var dropoffLocationLbl: UILabel!
    @IBOutlet weak var dropoffLocationTitleLbl: UILabel!
    
    @IBOutlet weak var actionBtn: RoundedShadowButton!
    @IBOutlet weak var centerMapBtn: UIButton!
    @IBOutlet var viewGesture: UITapGestureRecognizer!
    @IBOutlet weak var destinationCircle: CircleView!
    @IBOutlet weak var cancelBtn: UIButton!
    
    @IBOutlet weak var pickupCircleView: CircleView!
    @IBOutlet weak var mLocationView: RoundedShadowView!
    @IBOutlet weak var dropoffLocationView: RoundedShadowView!
    
    //MARK: - Variables
    
    var delegate: CenterVCDelegate?
    
    var manager: CLLocationManager?
    
    var currentUserId: String?
    
    var regionRadius: CLLocationDistance = 1000
    
    let revealingSplashView = RevealingSplashView(iconImage: UIImage(named: "launchScreenIcon")!, iconInitialSize: CGSize(width: 80, height: 80), backgroundColor: UIColor.white)
    var tableView = UITableView()
    
    var matchingPickup: MKMapItem?
    var matchingDropoff: MKMapItem?
    
    var route: MKRoute?
    var actionForButton: ButtonAction = .requestRide
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        initiateUIMode()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        mLocationView.addGestureRecognizer(viewGesture)
        self.currentUserId = Auth.auth().currentUser?.uid
        manager = CLLocationManager()
        manager?.delegate = self
        manager?.desiredAccuracy = kCLLocationAccuracyBest

        checkLocationAuthStatus()
        
        mapView.delegate = self
        centerMapOnUserLocation()
        
        DataService.instance.REF_DRIVERS.observe(.value, with: { (snapshot) in
            self.loadDriverAnnotationsFromFB()
            if Auth.auth().currentUser != nil {
                DataService.instance.passengerIsOnTrip(passengerKey: Auth.auth().currentUser!.uid, handler: { (isOnTrip, driverKey, tripKey) in
                    if isOnTrip == true {
                        self.zoom(toFitAnnotationsFromMapView: self.mapView, forActiveTripWithDriver: true, withKey: driverKey)
                    }
                })
            }
        })
        
        cancelBtn.alpha = 0.0
        
        self.view.addSubview(revealingSplashView)
        revealingSplashView.animationType = SplashAnimationType.heartBeat
        revealingSplashView.startAnimation()
        
        UpdateService.instance.observeTrips { (tripDict) in
            if let tripDict = tripDict {
                let pickupCoordinateArray = tripDict[USER_PICKUP_COORDINATE] as! NSArray
                let tripKey = tripDict[USER_PASSENGER_KEY] as! String
                let acceptanceStatus = tripDict[TRIP_IS_ACCEPTED] as! Bool
                
                if acceptanceStatus == false {
                    if self.currentUserId != nil {
                        DataService.instance.driverIsAvailable(key: self.currentUserId!, handler: { (available) in
                            if let available = available {
                                if available == true {
                                    let storyboard = UIStoryboard(name: MAIN_STORYBOARD, bundle: Bundle.main)
                                    let pickupVC = storyboard.instantiateViewController(withIdentifier: VC_PICKUP) as? PickupVC
                                    pickupVC?.initData(coordinate: CLLocationCoordinate2D(latitude: pickupCoordinateArray[0] as! CLLocationDegrees, longitude: pickupCoordinateArray[1] as! CLLocationDegrees), passengerKey: tripKey)
                                    self.present(pickupVC!, animated: true, completion: nil)
                                }
                            }
                        })
                    }
                }
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(onDidReceiveData(_:)), name: .didReceiveData, object: nil)
        initiateUIMode()
        self.currentUserId = Auth.auth().currentUser?.uid
        if currentUserId != nil {
            DataService.instance.userIsDriver(userKey: currentUserId!, handler: { (status) in
                if status == true {
                    self.buttonsForDriver(areHidden: true)
                }
            })
        }
        
        DataService.instance.REF_TRIPS.observe(.childRemoved, with: { (removedTripSnapshot) in
            let removedTripDict = removedTripSnapshot.value as? [String: AnyObject]
            if removedTripDict?[DRIVER_KEY] != nil {
                DataService.instance.REF_DRIVERS.child(removedTripDict?[DRIVER_KEY] as! String).updateChildValues([DRIVER_IS_ON_TRIP: false])
            }
            
            DataService.instance.userIsDriver(userKey: self.currentUserId!, handler: { (isDriver) in
                if isDriver == true {
                    self.removeOverlaysAndAnnotations(forDrivers: false, forPassengers: true)
                } else {
                    self.cancelBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
                    self.actionBtn.animateButton(shouldLoad: false, withMessage: MSG_REQUEST_RIDE)
                    
                    //enable editing dropoff
                    
                    self.removeOverlaysAndAnnotations(forDrivers: false, forPassengers: true)
                    self.centerMapOnUserLocation()
                }
            })
        })
        
        if currentUserId != nil {
            DataService.instance.driverIsOnTrip(driverKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                if isOnTrip == true {
                    DataService.instance.REF_TRIPS.observeSingleEvent(of: .value, with: { (tripSnapshot) in
                        if let tripSnapshot = tripSnapshot.children.allObjects as? [DataSnapshot] {
                            for trip in tripSnapshot {
                                if trip.childSnapshot(forPath: DRIVER_KEY).value as? String == self.currentUserId! {
                                    let pickupCoordinatesArray = trip.childSnapshot(forPath: USER_PICKUP_COORDINATE).value as! NSArray
                                    let pickupCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: pickupCoordinatesArray[0] as! CLLocationDegrees, longitude: pickupCoordinatesArray[1] as! CLLocationDegrees)
                                    let pickupPlacemark = MKPlacemark(coordinate: pickupCoordinate)
                                    
                                    self.dropPinFor(placemark: pickupPlacemark)
                                    self.searchMapKitForResultsWithPolyline(forOriginMapItem: nil, withDestinationMapItem: MKMapItem(placemark: pickupPlacemark))
                                    
                                    self.setCustomRegion(forAnnotationType: .pickup, withCoordinate: pickupCoordinate)
                                    
                                    self.actionForButton = .getDirectionsToPassenger
                                    self.actionBtn.setTitle(MSG_GET_DIRECTIONS, for: .normal)
                                    
                                    self.buttonsForDriver(areHidden: false)
                                }
                            }
                        }
                    })
                }
            })
            connectUserAndDriverForTrip()
        }
    }
    
    func checkLocationAuthStatus() {
        if CLLocationManager.authorizationStatus() == .authorizedAlways {
            manager?.startUpdatingLocation()
        } else {
            manager?.requestAlwaysAuthorization()
        }
    }
    //MARK: - Driver functions
    func buttonsForDriver(areHidden: Bool) {
        if areHidden {
            self.actionBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
            self.cancelBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
            self.centerMapBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
            self.actionBtn.isHidden = true
            self.cancelBtn.isHidden = true
            self.centerMapBtn.isHidden = true
        } else {
            self.actionBtn.fadeTo(alphaValue: 1.0, withDuration: 0.2)
            self.cancelBtn.fadeTo(alphaValue: 1.0, withDuration: 0.2)
            self.centerMapBtn.fadeTo(alphaValue: 1.0, withDuration: 0.2)
            self.actionBtn.isHidden = false
            self.cancelBtn.isHidden = false
            self.centerMapBtn.isHidden = false
        }
    }
    
    func loadDriverAnnotationsFromFB() {
        DataService.instance.REF_DRIVERS.observeSingleEvent(of: .value, with: { (snapshot) in
            if let driverSnapshot = snapshot.children.allObjects as? [DataSnapshot] {
                for driver in driverSnapshot {
                    if driver.hasChild(COORDINATE) {
                        if driver.childSnapshot(forPath: ACCOUNT_PICKUP_MODE_ENABLED).value as? Bool == true {
                            if let driverDict = driver.value as? Dictionary<String, AnyObject> {
                                let coordinateArray = driverDict[COORDINATE] as! NSArray
                                let driverCoordinate = CLLocationCoordinate2D(latitude: coordinateArray[0] as! CLLocationDegrees, longitude: coordinateArray[1] as! CLLocationDegrees)
                                
                                let annotation = DriverAnnotation(coordinate: driverCoordinate, withKey: driver.key)
                                
                                var driverIsVisible: Bool {
                                    return self.mapView.annotations.contains(where: { (annotation) -> Bool in
                                        if let driverAnnotation = annotation as? DriverAnnotation {
                                            if driverAnnotation.key == driver.key {
                                                driverAnnotation.update(annotationPosition: driverAnnotation, withCoordinate: driverCoordinate)
                                                return true
                                            }
                                        }
                                        return false
                                    })
                                }
                                
                                if !driverIsVisible {
                                    self.mapView.addAnnotation(annotation)
                                }
                            }
                        } else {
                            for annotation in self.mapView.annotations {
                                if annotation.isKind(of: DriverAnnotation.self) {
                                    if let annotation = annotation as? DriverAnnotation {
                                        if annotation.key == driver.key {
                                            self.mapView.removeAnnotation(annotation)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        })
        revealingSplashView.heartAttack = true
    }
    
    func connectUserAndDriverForTrip() {
        DataService.instance.passengerIsOnTrip(passengerKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
            if isOnTrip == true {
                self.removeOverlaysAndAnnotations(forDrivers: false, forPassengers: true)
                
                DataService.instance.REF_TRIPS.child(tripKey!).observeSingleEvent(of: .value, with: { (tripSnapshot) in
                    let tripDict = tripSnapshot.value as? Dictionary<String, AnyObject>
                    let driverId = tripDict?[DRIVER_KEY] as! String
                    
                    let pickupCoordinateArray = tripDict?[USER_PICKUP_COORDINATE] as! NSArray
                    let pickupCoordinate = CLLocationCoordinate2D(latitude: pickupCoordinateArray[0] as! CLLocationDegrees, longitude: pickupCoordinateArray[1] as! CLLocationDegrees)
                    let pickupPlacemark = MKPlacemark(coordinate: pickupCoordinate)
                    let pickupMapItem = MKMapItem(placemark: pickupPlacemark)
                    DataService.instance.REF_DRIVERS.child(driverId).child(COORDINATE).observeSingleEvent(of: .value, with: { (coordinateSnapshot) in
                        let coordinateSnapshot = coordinateSnapshot.value as! NSArray
                        let driverCoordinate = CLLocationCoordinate2D(latitude: coordinateSnapshot[0] as! CLLocationDegrees, longitude: coordinateSnapshot[1] as! CLLocationDegrees)
                        let driverPlacemark = MKPlacemark(coordinate: driverCoordinate)
                        let driverMapItem = MKMapItem(placemark: driverPlacemark)
                        
                        let passengerAnnotation = PassengerAnnotation(coordinate: pickupCoordinate, key: self.currentUserId!)
                        self.mapView.addAnnotation(passengerAnnotation)
                        
                        self.searchMapKitForResultsWithPolyline(forOriginMapItem: driverMapItem, withDestinationMapItem: pickupMapItem)
                        self.actionBtn.animateButton(shouldLoad: false, withMessage: MSG_DRIVER_COMING)
                        self.actionBtn.isUserInteractionEnabled = false
                    })
                    
                    DataService.instance.REF_TRIPS.child(tripKey!).observeSingleEvent(of: .value, with: { (tripSnapshot) in
                        if tripDict?[TRIP_IN_PROGRESS] as? Bool == true {
                            self.removeOverlaysAndAnnotations(forDrivers: true, forPassengers: true)
                            
                            let destinationCoordinateArray = tripDict?[USER_DESTINATION_COORDINATE] as! NSArray
                            let destinationCoordinate = CLLocationCoordinate2D(latitude: destinationCoordinateArray[0] as! CLLocationDegrees, longitude: destinationCoordinateArray[1] as! CLLocationDegrees)
                            let destinationPlacemark = MKPlacemark(coordinate: destinationCoordinate)
                            
                            self.dropPinFor(placemark: destinationPlacemark)
                            self.searchMapKitForResultsWithPolyline(forOriginMapItem: pickupMapItem, withDestinationMapItem: MKMapItem(placemark: destinationPlacemark))
                            
                            self.actionBtn.setTitle(MSG_ON_TRIP, for: .normal)
                        }
                    })
                })
            }
        })
    }
    
    func centerMapOnUserLocation() {
        let coordinateRegion = MKCoordinateRegion(center: mapView.userLocation.coordinate, latitudinalMeters: regionRadius * 2.0, longitudinalMeters: regionRadius * 2.0)
        mapView.setRegion(coordinateRegion, animated: true)
    }
    
    func buttonSelector(forAction action: ButtonAction) {
        switch action {
        case .confirmPickup:
            print("confirm")
        case .confirmDropoff:
            print("confirm")
        case .requestRide:
            if matchingDropoff != nil {
                UpdateService.instance.updateTripsWithCoordinatesUponRequest()
                actionBtn.animateButton(shouldLoad: true, withMessage: nil)
                cancelBtn.fadeTo(alphaValue: 1.0, withDuration: 0.2)
                
            }
        case .getDirectionsToPassenger:
            DataService.instance.driverIsOnTrip(driverKey: currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                if isOnTrip == true {
                    DataService.instance.REF_TRIPS.child(tripKey!).observe(.value, with: { (tripSnapshot) in
                        let tripDict = tripSnapshot.value as? Dictionary<String, AnyObject>
                        
                        let pickupCoordinateArray = tripDict?[USER_PICKUP_COORDINATE] as! NSArray
                        let pickupCoordinate = CLLocationCoordinate2D(latitude: pickupCoordinateArray[0] as! CLLocationDegrees, longitude: pickupCoordinateArray[1] as! CLLocationDegrees)
                        let pickupMapItem = MKMapItem(placemark: MKPlacemark(coordinate: pickupCoordinate))
                        
                        pickupMapItem.name = MSG_PASSENGER_PICKUP
                        pickupMapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey:MKLaunchOptionsDirectionsModeDriving])
                    })
                }
            })
        case .startTrip:
            DataService.instance.driverIsOnTrip(driverKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                if isOnTrip == true {
                    self.removeOverlaysAndAnnotations(forDrivers: false, forPassengers: false)
                    
                    DataService.instance.REF_TRIPS.child(tripKey!).updateChildValues([TRIP_IN_PROGRESS: true])
                    
                    DataService.instance.REF_TRIPS.child(tripKey!).child(USER_DESTINATION_COORDINATE).observeSingleEvent(of: .value, with: { (coordinateSnapshot) in
                        let destinationCoordinateArray = coordinateSnapshot.value as! NSArray
                        let destinationCoordinate = CLLocationCoordinate2D(latitude: destinationCoordinateArray[0] as! CLLocationDegrees, longitude: destinationCoordinateArray[1] as! CLLocationDegrees)
                        let destinationPlacemark = MKPlacemark(coordinate: destinationCoordinate)
                        
                        self.dropPinFor(placemark: destinationPlacemark)
                        self.searchMapKitForResultsWithPolyline(forOriginMapItem: nil, withDestinationMapItem: MKMapItem(placemark: destinationPlacemark))
                        self.setCustomRegion(forAnnotationType: .destination, withCoordinate: destinationCoordinate)
                        
                        self.actionForButton = .getDirectionsToDestination
                        self.actionBtn.setTitle(MSG_GET_DIRECTIONS, for: .normal)
                    })
                }
            })
        case .getDirectionsToDestination:
            DataService.instance.driverIsOnTrip(driverKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                if isOnTrip == true {
                    DataService.instance.REF_TRIPS.child(tripKey!).child(USER_DESTINATION_COORDINATE).observe(.value, with: { (snapshot) in
                        let destinationCoordinateArray = snapshot.value as! NSArray
                        let destinationCoordinate = CLLocationCoordinate2D(latitude: destinationCoordinateArray[0] as! CLLocationDegrees, longitude: destinationCoordinateArray[1] as! CLLocationDegrees)
                        let destinationPlacemark = MKPlacemark(coordinate: destinationCoordinate)
                        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)
                        
                        destinationMapItem.name = MSG_PASSENGER_DESTINATION
                        destinationMapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey:MKLaunchOptionsDirectionsModeDriving])
                    })
                }
            })
        case .endTrip:
            DataService.instance.driverIsOnTrip(driverKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                if isOnTrip == true {
                    UpdateService.instance.cancelTrip(withPassengerKey: tripKey!, forDriverKey: driverKey!)
                    self.buttonsForDriver(areHidden: true)
                }
            })
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    //MARK: - IBActions
    @IBAction func actionBtnWasPressed(_ sender: Any) {
        buttonSelector(forAction: actionForButton)
    }
    
    @IBAction func cancelBtnWasPressed(_ sender: Any) {
        DataService.instance.driverIsOnTrip(driverKey: currentUserId!) { (isOnTrip, driverKey, tripKey) in
            if isOnTrip == true {
                UpdateService.instance.cancelTrip(withPassengerKey: tripKey!, forDriverKey: driverKey!)
            }
        }
        
        DataService.instance.passengerIsOnTrip(passengerKey: currentUserId!) { (isOnTrip, driverKey, tripKey) in
            if isOnTrip == true {
                UpdateService.instance.cancelTrip(withPassengerKey: self.currentUserId!, forDriverKey: driverKey!)
            } else {
                self.removeOverlaysAndAnnotations(forDrivers: false, forPassengers: true)
                self.centerMapOnUserLocation()
            }
        }
        
        self.actionBtn.isUserInteractionEnabled = true
    }
    
    @IBAction func centerMapBtnWasPressed(_ sender: Any) {
        DataService.instance.REF_USERS.observeSingleEvent(of: .value, with: { (snapshot) in
            if let userSnapshot = snapshot.children.allObjects as? [DataSnapshot] {
                for user in userSnapshot {
                    if user.key == self.currentUserId! {
                        if user.hasChild(TRIP_COORDINATE) {
                            self.zoom(toFitAnnotationsFromMapView: self.mapView, forActiveTripWithDriver: false, withKey: nil)
                            self.centerMapBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
                        } else {
                            self.centerMapOnUserLocation()
                            self.centerMapBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
                        }
                    }
                }
            }
        })
    }
    
    @IBAction func menuBtnWasPressed(_ sender: Any) {
        delegate?.toggleLeftPanel()
    }
    
    @IBAction func locationViewTapped(_ sender: Any) {
        //performSegue(withIdentifier: "toSearchVC", sender: nil)
        
        if let searchVC = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "searchVC") as? SearchTableViewController {
            self.present(searchVC, animated: true, completion: nil)
        }
    }
    
    @objc func onDidReceiveData(_ notification:Notification) {
        guard let dropoff = notification.userInfo?["dropoff"] as? MKMapItem else { return }
        let pickup = notification.userInfo?["pickup"] as? MKMapItem
        matchingDropoff = dropoff
        matchingPickup = pickup ?? nil
        pickupCircleView.isHidden = false
        dropoffLocationView.isHidden = false
        pickupCircleView.backgroundColor = UIColor.gray
        dropoffLocationLbl.text = dropoff.name
        dropoffLocationTitleLbl.text = dropoff.placemark.title
        if pickup != nil {
            pickupLocationLbl.text = pickup!.name
            pickupLocationTitleLbl.text = pickup!.placemark.title
            setupMatching(pickupMapItem: pickup, dropoffMapItem: dropoff)
        } else {
            UpdateService.instance.lookUpCurrentLocation { (currentPlacemark) in
                guard let currentPlacemark = currentPlacemark else { return }
                self.pickupLocationLbl.text = currentPlacemark.name! + (" (Your Location)")
                self.pickupLocationLbl.textColor = UIColor.gray
            }
            pickupLocationTitleLbl.text = ""
            setupMatching(pickupMapItem: nil, dropoffMapItem: dropoff)
        }
//        if matchingDropoff == nil && matchingPickup == nil {
//            dropoffLocationView.isHidden = true
//            pickupLocationLbl.text = "Where to?"
//            pickupLocationLbl.textColor = UIColor.gray
//            pickupLocationTitleLbl.text = ""
//        }
    }
    
}

extension HomeVC: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways {
            mapView.showsUserLocation = true
            mapView.userTrackingMode = .follow
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        DataService.instance.driverIsOnTrip(driverKey: currentUserId!, handler: { (isOnTrip, driverKey, passengerKey) in
            if isOnTrip == true {
                if region.identifier == REGION_PICKUP {
                    self.actionForButton = .startTrip
                    self.actionBtn.setTitle(MSG_START_TRIP, for: .normal)
                } else if region.identifier == REGION_DESTINATION {
                    self.cancelBtn.fadeTo(alphaValue: 0.0, withDuration: 0.2)
                    self.cancelBtn.isHidden = true
                    self.actionForButton = .endTrip
                    self.actionBtn.setTitle(MSG_END_TRIP, for: .normal)
                }
            }
        })
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        DataService.instance.driverIsOnTrip(driverKey: currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
            if isOnTrip == true {
                if region.identifier == REGION_PICKUP {
                    self.actionForButton = .getDirectionsToPassenger
                    self.actionBtn.setTitle(MSG_GET_DIRECTIONS, for: .normal)
                } else if region.identifier == REGION_DESTINATION {
                    self.actionForButton = .getDirectionsToDestination
                    self.actionBtn.setTitle(MSG_GET_DIRECTIONS, for: .normal)
                }
            }
        })
    }
}

extension HomeVC: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        UpdateService.instance.updateUserLocation(withCoordinate: userLocation.coordinate)
        UpdateService.instance.updateDriverLocation(withCoordinate: userLocation.coordinate)
        
        if currentUserId != nil {
            DataService.instance.userIsDriver(userKey: currentUserId!) { (isDriver) in
                if isDriver == true {
                    DataService.instance.driverIsOnTrip(driverKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                        if isOnTrip == true {
                            self.zoom(toFitAnnotationsFromMapView: self.mapView, forActiveTripWithDriver: true, withKey: driverKey)
                        } else {
                            self.centerMapOnUserLocation()
                        }
                    })
                } else {
                    DataService.instance.passengerIsOnTrip(passengerKey: self.currentUserId!, handler: { (isOnTrip, driverKey, tripKey) in
                        if isOnTrip == true {
                            self.zoom(toFitAnnotationsFromMapView: self.mapView, forActiveTripWithDriver: true, withKey: driverKey)
                        } else {
                            self.centerMapOnUserLocation()
                        }
                    })
                }
            }
        }
    }
    
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let annotation = annotation as? DriverAnnotation {
            let identifier = "driver"
            var view: MKAnnotationView
            view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.image = UIImage(named: ANNO_DRIVER)
            return view
        } else if let annotation = annotation as? PassengerAnnotation {
            let identifier = "passenger"
            var view: MKAnnotationView
            view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.image = UIImage(named: ANNO_PICKUP)
            return view
        } else if let annotation = annotation as? MKPointAnnotation {
            let identifier = "destination"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            } else {
                annotationView?.annotation = annotation
            }
            annotationView?.image = UIImage(named: ANNO_DESTINATION)
            return annotationView
        }
        return nil
    }
    
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        centerMapBtn.fadeTo(alphaValue: 1.0, withDuration: 0.2)
    }
    
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let lineRenderer = MKPolylineRenderer(overlay: (self.route?.polyline)!)
        lineRenderer.strokeColor = UIColor(red: 216/255, green: 71/255, blue: 30/255, alpha: 0.75)
        lineRenderer.lineWidth = 3
        
        shouldPresentLoadingView(false)
        
        return lineRenderer
    }
    
    func dropPinFor(placemark: MKPlacemark) {
        
        for annotation in mapView.annotations {
            if annotation.isKind(of: MKPointAnnotation.self) {
                mapView.removeAnnotation(annotation)
            }
        }
        
        let annotation = MKPointAnnotation()
        annotation.coordinate = placemark.coordinate
        mapView.addAnnotation(annotation)
    }
    
    func searchMapKitForResultsWithPolyline(forOriginMapItem originMapItem: MKMapItem?, withDestinationMapItem destinationMapItem: MKMapItem) {
        let request = MKDirections.Request()
        
        if originMapItem == nil {
            request.source = MKMapItem.forCurrentLocation()
        } else {
            request.source = originMapItem
        }
        
        request.destination = destinationMapItem
        request.transportType = MKDirectionsTransportType.automobile
        request.requestsAlternateRoutes = true
        
        let directions = MKDirections(request: request)
        
        directions.calculate { (response, error) in
            guard let response = response else {
                self.showAlert(error.debugDescription)
                return
            }
            self.route = response.routes[0]
            self.mapView.addOverlay(self.route!.polyline)
            
            self.zoom(toFitAnnotationsFromMapView: self.mapView, forActiveTripWithDriver: false, withKey: nil)
            
            let delegate = AppDelegate.getAppDelegate()
            delegate.window?.rootViewController?.shouldPresentLoadingView(false)
        }
    }
    
    func zoom(toFitAnnotationsFromMapView mapView: MKMapView, forActiveTripWithDriver: Bool, withKey key: String?) {
        if mapView.annotations.count == 0 {
            return
        }
        
        var topLeftCoordinate = CLLocationCoordinate2D(latitude: -90, longitude: 180)
        var bottomRightCoordinate = CLLocationCoordinate2D(latitude: 90, longitude: -180)
        
        
        if forActiveTripWithDriver {
            for annotation in mapView.annotations {
                if let annotation = annotation as? DriverAnnotation {
                    if annotation.key == key {
                        topLeftCoordinate.longitude = fmin(topLeftCoordinate.longitude, annotation.coordinate.longitude)
                        topLeftCoordinate.latitude = fmax(topLeftCoordinate.latitude, annotation.coordinate.latitude)
                        bottomRightCoordinate.longitude = fmax(bottomRightCoordinate.longitude, annotation.coordinate.longitude)
                        bottomRightCoordinate.latitude = fmin(bottomRightCoordinate.latitude, annotation.coordinate.latitude)
                    }
                } else {
                    topLeftCoordinate.longitude = fmin(topLeftCoordinate.longitude, annotation.coordinate.longitude)
                    topLeftCoordinate.latitude = fmax(topLeftCoordinate.latitude, annotation.coordinate.latitude)
                    bottomRightCoordinate.longitude = fmax(bottomRightCoordinate.longitude, annotation.coordinate.longitude)
                    bottomRightCoordinate.latitude = fmin(bottomRightCoordinate.latitude, annotation.coordinate.latitude)
                }
            }
        }
        
        
        for annotation in mapView.annotations where !annotation.isKind(of: DriverAnnotation.self) {
            topLeftCoordinate.longitude = fmin(topLeftCoordinate.longitude, annotation.coordinate.longitude)
            topLeftCoordinate.latitude = fmax(topLeftCoordinate.latitude, annotation.coordinate.latitude)
            bottomRightCoordinate.longitude = fmax(bottomRightCoordinate.longitude, annotation.coordinate.longitude)
            bottomRightCoordinate.latitude = fmin(bottomRightCoordinate.latitude, annotation.coordinate.latitude)
        }
        
        var region = MKCoordinateRegion(center: CLLocationCoordinate2DMake(topLeftCoordinate.latitude - (topLeftCoordinate.latitude - bottomRightCoordinate.latitude) * 0.5, topLeftCoordinate.longitude + (bottomRightCoordinate.longitude - topLeftCoordinate.longitude) * 0.5), span: MKCoordinateSpan(latitudeDelta: fabs(topLeftCoordinate.latitude - bottomRightCoordinate.latitude) * 2.0, longitudeDelta: fabs(bottomRightCoordinate.longitude - topLeftCoordinate.longitude) * 2.0))
        
        region = mapView.regionThatFits(region)
        mapView.setRegion(region, animated: true)
    }
    
    func removeOverlaysAndAnnotations(forDrivers: Bool?, forPassengers: Bool?) {
        
        for annotation in mapView.annotations {
            if let annotation = annotation as? MKPointAnnotation {
                mapView.removeAnnotation(annotation)
            }
            
            if forPassengers! {
                if let annotation = annotation as? PassengerAnnotation {
                    mapView.removeAnnotation(annotation)
                }
            }
            
            if forDrivers! {
                if let annotation = annotation as? DriverAnnotation {
                    mapView.removeAnnotation(annotation)
                }
            }
        }
        
        for overlay in mapView.overlays {
            if overlay is MKPolyline {
                mapView.removeOverlay(overlay)
            }
        }
    }
    
    func setCustomRegion(forAnnotationType type: AnnotationType, withCoordinate coordinate: CLLocationCoordinate2D) {
        if type == .pickup {
            let pickupRegion = CLCircularRegion(center: coordinate, radius: 100, identifier: REGION_PICKUP)
            manager?.startMonitoring(for: pickupRegion)
        } else if type == .destination {
            let destinationRegion = CLCircularRegion(center: coordinate, radius: 100, identifier: REGION_DESTINATION)
            manager?.startMonitoring(for: destinationRegion)
        }
    }
    //MARK: Helper Functions
    func initiateUIMode() {
        dropoffLocationView.isHidden = true
        pickupLocationLbl.textColor = UIColor.darkGray
        pickupLocationLbl.text = "Where to?"
        pickupLocationTitleLbl.isHidden = true
        pickupCircleView.isHidden = true
        if matchingDropoff != nil {
            if matchingPickup != nil {
                pickupCircleView.isHidden = false
                pickupCircleView.backgroundColor = UIColor.gray
                dropoffLocationView.isHidden = false
                dropoffLocationLbl.text = matchingDropoff!.name
                dropoffLocationTitleLbl.text = matchingDropoff!.placemark.title
                pickupLocationLbl.text = matchingPickup!.name
                pickupLocationTitleLbl.text = matchingPickup!.placemark.title
            } else {
                pickupCircleView.backgroundColor = UIColor.gray
                dropoffLocationView.isHidden = false
                dropoffLocationLbl.text = matchingDropoff!.name
                dropoffLocationTitleLbl.text = matchingDropoff!.placemark.title
                UpdateService.instance.lookUpCurrentLocation { (currentPlacemark) in
                    guard let currentPlacemark = currentPlacemark else { return }
                    self.pickupLocationLbl.text = currentPlacemark.name! + (" (Your Location)")
                    self.pickupLocationLbl.textColor = UIColor.gray
                }
                pickupLocationTitleLbl.text = ""
            }
        } else if matchingDropoff == nil && matchingPickup == nil {
            dropoffLocationView.isHidden = true
            pickupLocationLbl.text = "Where to?"
            pickupLocationLbl.textColor = UIColor.gray
            pickupLocationTitleLbl.text = ""
        }
    }
    
    func setupMatching(pickupMapItem pickup: MKMapItem?, dropoffMapItem dropoff: MKMapItem) {
        var passengerCoordinate: CLLocationCoordinate2D?
        if pickup != nil {
            if pickup!.isCurrentLocation {
                passengerCoordinate = manager?.location?.coordinate
            } else {
                passengerCoordinate = pickup!.placemark.coordinate
            }
            DataService.instance.REF_USERS.child(Auth.auth().currentUser!.uid)
                .updateChildValues([TRIP_COORDINATE:
                    [pickup!.placemark.coordinate.latitude, pickup!.placemark.coordinate.longitude]])
        } else {
            passengerCoordinate = manager?.location?.coordinate
            DataService.instance.REF_USERS.child(Auth.auth().currentUser!.uid)
                .updateChildValues([TRIP_COORDINATE:
                    [manager?.location?.coordinate.latitude,manager?.location?.coordinate.longitude]])
        }
        
        //guard passengerCoordinate != nil else { return }
        let passengerAnnotation = PassengerAnnotation(coordinate: passengerCoordinate!, key: Auth.auth().currentUser!.uid)
        self.mapView.addAnnotation(passengerAnnotation)
        dropPinFor(placemark: dropoff.placemark)
        if pickup != nil {
            searchMapKitForResultsWithPolyline(forOriginMapItem: pickup, withDestinationMapItem: dropoff)
        } else {
            searchMapKitForResultsWithPolyline(forOriginMapItem: nil, withDestinationMapItem: dropoff)
        }
    }
}

extension Notification.Name {
    static let didReceiveData = Notification.Name("didReceiveData")
    static let didCompleteTask = Notification.Name("didCompleteTask")
    static let completedLengthyDownload = Notification.Name("completedLengthyDownload")
}
