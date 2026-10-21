import SwiftUI
import UIKit

struct PrimaryActionStyle: ButtonStyle {
    var secondary=false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth:.infinity,minHeight:50)
            .padding(.horizontal,12).padding(.vertical,2)
            .foregroundStyle(secondary ? Color.primary : Color.white)
            .background(secondary ? Color(uiColor:.tertiarySystemFill) : Color.accentColor,in:RoundedRectangle(cornerRadius:14))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius:14))
    }
}
struct NoticeCard: View {
    let title:String, message:String, symbol:String
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label(title,systemImage:symbol).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
            .background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
    }
}
struct GuideStep: View {
    let number:Int, title:String, detail:String
    var body: some View {
        HStack(alignment:.top,spacing:14) {
            Text("\(number)").font(.headline).foregroundStyle(.tint).frame(width:32,height:32)
                .background(Color.accentColor.opacity(0.1),in:Circle()).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:7) { Text(title).font(.headline);Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
struct CropCanvas: View {
    let image:UIImage
    let size:PixelSize
    let insets:CaptureInsets
    let enabled:Bool
    var collage=false
    let change:(String,Int)->Void
    @State private var draggingEdge:String?
    @State private var translation:CGFloat=0
    var body:some View {
        GeometryReader { geometry in
            let ratio=CGFloat(size.width)/CGFloat(size.height)
            let width=min(geometry.size.width,geometry.size.height*ratio)
            let height=width/ratio
            let rect=CGRect(x:(geometry.size.width-width)/2,y:(geometry.size.height-height)/2,width:width,height:height)
            let selection=draggingEdge.map { dragged(edge:$0,translation:Double(translation),length:Double($0 == "top" || $0 == "bottom" ? height : width)) } ?? insets
            let crop=CGRect(x:rect.minX+CGFloat(selection.left)/CGFloat(size.width)*width,
                            y:rect.minY+CGFloat(selection.top)/CGFloat(size.height)*height,
                            width:CGFloat(size.width-selection.left-selection.right)/CGFloat(size.width)*width,
                            height:CGFloat(size.height-selection.top-selection.bottom)/CGFloat(size.height)*height)
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:16).fill(Color(uiColor:.tertiarySystemFill))
                Image(uiImage:image).resizable().frame(width:width,height:height).position(x:rect.midX,y:rect.midY).accessibilityHidden(true)
                Path { p in p.addRect(rect);p.addRect(crop) }.fill(.black.opacity(0.4),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                Rectangle().stroke(Color.accentColor,lineWidth:2).frame(width:crop.width,height:crop.height).position(x:crop.midX,y:crop.midY).allowsHitTesting(false)
                handle("top",title:"上边界",value:selection.top,length:height,point:CGPoint(x:crop.midX,y:crop.minY))
                handle("bottom",title:"下边界",value:selection.bottom,length:height,point:CGPoint(x:crop.midX,y:crop.maxY))
                handle("left",title:"左边界",value:selection.left,length:width,point:CGPoint(x:crop.minX,y:crop.midY))
                handle("right",title:"右边界",value:selection.right,length:width,point:CGPoint(x:crop.maxX,y:crop.midY))
            }.clipShape(RoundedRectangle(cornerRadius:16))
        }
    }
    private func dragged(edge:String,translation:Double,length:Double)->CaptureInsets {
        collage ? insets.draggingForCollage(edge:edge,translation:translation,displayedLength:length,in:size) :
            insets.dragging(edge:edge,translation:translation,displayedLength:length,in:size)
    }
    private func handle(_ edge:String,title:String,value:Int,length:CGFloat,point:CGPoint)->some View {
        let vertical=edge == "top" || edge == "bottom"
        return Capsule().fill(Color.accentColor).overlay(Capsule().stroke(.white,lineWidth:1))
            .frame(width:vertical ? 32 : 7,height:vertical ? 7 : 32)
            .frame(width:44,height:44).contentShape(Rectangle()).position(point)
            .gesture(DragGesture(minimumDistance:0).onChanged { gesture in
                guard enabled else { return };draggingEdge=edge;translation=vertical ? gesture.translation.height : gesture.translation.width
            }.onEnded { gesture in
                guard enabled else { return }
                let selected=dragged(edge:edge,translation:Double(vertical ? gesture.translation.height : gesture.translation.width),length:Double(length))
                change(edge,edge == "top" ? selected.top : edge == "bottom" ? selected.bottom : edge == "left" ? selected.left : selected.right)
                draggingEdge=nil;translation=0
            })
            .accessibilityElement().accessibilityLabel(title)
            .accessibilityValue("已去除 \(Int(Double(value)/Double(vertical ? size.height : size.width)*100))%")
            .accessibilityHint("上下轻扫调整，也可以使用下方精细调整")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                change(edge,value+(direction == .increment ? 8 : -8))
            }
    }
}

struct ZoomableResult: UIViewRepresentable {
    let image:UIImage
    let zoomCommand:Int
    func makeUIView(context:Context)->ResultScrollView {
        let view=ResultScrollView();view.setImage(image);view.lastCommand=zoomCommand;return view
    }
    func updateUIView(_ view:ResultScrollView,context:Context) {
        view.setImage(image)
        if view.lastCommand != zoomCommand {
            let next=view.zoomScale*(zoomCommand>view.lastCommand ? 1.5 : 1/1.5)
            view.setZoomScale(max(view.minimumZoomScale,min(view.maximumZoomScale,next)),animated:true)
            view.lastCommand=zoomCommand
        }
    }
}
final class ResultScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView=UIImageView()
    private var lastWidth:CGFloat=0
    var lastCommand=0
    override init(frame:CGRect) {
        super.init(frame:frame)
        delegate=self;minimumZoomScale=1;maximumZoomScale=5
        backgroundColor = .secondarySystemBackground
        alwaysBounceVertical=true;showsVerticalScrollIndicator=true
        imageView.isAccessibilityElement=true;imageView.accessibilityLabel="完整图片预览"
        imageView.accessibilityHint="可滚动阅读，或使用上方放大与缩小按钮"
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap=UITapGestureRecognizer(target:self,action:#selector(toggleZoom(_:)));doubleTap.numberOfTapsRequired=2;addGestureRecognizer(doubleTap)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image:UIImage) {
        guard imageView.image !== image else { return }
        imageView.image=image;lastWidth=0;setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image=imageView.image,bounds.width>0 else { return }
        if abs(bounds.width-lastWidth)>0.5 {
            lastWidth=bounds.width;zoomScale=1
            let width=bounds.width
            imageView.frame=CGRect(x:0,y:0,width:width,height:width*image.size.height/image.size.width)
            contentSize=imageView.bounds.size
        }
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView? { imageView }
    @objc private func toggleZoom(_ gesture:UITapGestureRecognizer) {
        if zoomScale>1.01 { setZoomScale(1,animated:true) }
        else {
            let point=gesture.location(in:imageView),scale:CGFloat=2.5
            let target=CGRect(x:point.x-bounds.width/(2*scale),y:point.y-bounds.height/(2*scale),width:bounds.width/scale,height:bounds.height/scale)
            zoom(to:target,animated:true)
        }
    }
}
