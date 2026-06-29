import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "NoMoreChaos")

        if inMemory {
            container.persistentStoreDescriptions.first?.url =
                URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Core Data load error: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Preview

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext

        let project = Project(context: ctx)
        project.id = UUID()
        project.name = "Demo Project"
        project.colorHex = "#0A84FF"
        project.sortOrder = 0
        project.createdAt = Date()

        try? ctx.save()
        return controller
    }()
}
