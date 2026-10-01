import Foundation

/// A small fixed-step rigid-rod system. Contact transfers angular momentum;
/// completed work unlocks bodies, so physics can never invent loading progress.
struct KingDominoPhysics {
    private(set) var angles=Array(repeating:0.0,count:10)
    private(set) var velocities=Array(repeating:0.0,count:10)
    private(set) var impacts=Array(repeating:0.0,count:10)
    private(set) var collisions=0
    private var accumulator=0.0
    private var touched=Array(repeating:false,count:9)
    private var unlocked=0
    private let height=1.45,contactWidth=0.42,floorAngle=Double.pi*0.455
    mutating func advance(seconds:Double,completed:Int) {
        let count=max(0,min(10,completed))
        if count>unlocked {
            // A domino held upright by an unfinished stage receives a gentle
            // release impulse once work completes, including after a long pause.
            if unlocked==0 {velocities[0]=1.15}
            else if angles[unlocked-1]>0.25 {velocities[unlocked]=max(velocities[unlocked],0.85)}
            unlocked=count
        }
        accumulator+=max(0,min(0.1,seconds))
        let dt=1.0/240
        while accumulator+1e-10>=dt {
            accumulator-=dt
            for i in 0..<10 {
                impacts[i]*=exp(-dt*12)
                guard i<unlocked else{angles[i]=0;velocities[i]=0;continue}
                if angles[i]>0 || velocities[i]>0 {
                    velocities[i]+=(14*sin(angles[i])-1.5*velocities[i])*dt
                    angles[i]+=velocities[i]*dt
                }
                if angles[i]>=floorAngle {
                    angles[i]=floorAngle
                    if velocities[i]>0.25 {impacts[i]=min(1,velocities[i]/5);velocities[i] *= -0.13}
                    else {velocities[i]=0}
                }
                if angles[i]<0 {angles[i]=0;velocities[i]=0}
            }
            // Solve from the ground-contact end back toward the first king.
            for i in stride(from:8,through:0,by:-1) {
                let a=angles[i],b=angles[i+1]
                let cap=b+asin(max(-1,min(1,(cos(b)-contactWidth)/height)))
                guard a>cap else{continue}
                let incoming=max(0,velocities[i]-velocities[i+1])
                angles[i]=max(0,cap)
                if !touched[i] && incoming>0.05 {
                    touched[i]=true;collisions+=1;impacts[i+1]=min(1,incoming/3)
                }
                if i+1<unlocked {
                    velocities[i+1]=min(5,velocities[i+1]+incoming*0.72)
                    velocities[i]=velocities[i+1]*0.62
                } else {velocities[i]=0}
            }
        }
    }
}
